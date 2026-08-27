import AppKit
import AVFoundation
import CoreMedia
import SwiftUI

final class H264FrameBus: @unchecked Sendable {
    private let lock = NSLock()
    private weak var renderer: H264MirrorView?
    private var pendingPackets: [(Data, UInt64)] = []
    private var frameTimes: [Date] = []
    private var lastReport = Date.distantPast

    @MainActor
    func attach(_ renderer: H264MirrorView) {
        lock.lock()
        self.renderer = renderer
        let packets = pendingPackets
        pendingPackets.removeAll(keepingCapacity: true)
        lock.unlock()
        packets.forEach { renderer.enqueueH264($0.0, pts: $0.1) }
    }

    func deliver(data: Data, presentationTime: UInt64) {
        lock.lock()
        let target = renderer
        if target == nil {
            pendingPackets.append((data, presentationTime))
            if pendingPackets.count > 12 { pendingPackets.removeFirst(pendingPackets.count - 12) }
        }
        lock.unlock()
        target?.enqueueH264(data, pts: presentationTime)
    }

    func noteFrame(at now: Date = Date()) -> Double? {
        lock.lock()
        frameTimes.append(now)
        frameTimes.removeAll { now.timeIntervalSince($0) > 1 }
        guard now.timeIntervalSince(lastReport) >= 0.25,
              frameTimes.count > 1, let first = frameTimes.first else {
            lock.unlock()
            return nil
        }
        lastReport = now
        let fps = Double(frameTimes.count - 1) / max(now.timeIntervalSince(first), 0.01)
        lock.unlock()
        return fps
    }

    @MainActor
    func reset() {
        lock.lock()
        let target = renderer
        pendingPackets.removeAll(keepingCapacity: true)
        frameTimes.removeAll()
        lastReport = .distantPast
        lock.unlock()
        target?.resetDecoder()
    }
}

struct H264MirrorCanvas: NSViewRepresentable {
    @ObservedObject var store: MirrorStore

    func makeNSView(context: Context) -> H264MirrorView {
        let view = H264MirrorView()
        view.commandHandler = { [weak store] command in store?.send(command) }
        store.h264Video.attach(view)
        return view
    }

    func updateNSView(_ view: H264MirrorView, context: Context) {
        view.screenSize = store.details.resolution
        view.usesRealtimeTouch = store.selectedPlatform == .android || store.harmonyRealtimeTouch
        view.inputPlatform = store.selectedPlatform ?? .android
        store.h264Video.attach(view)
    }
}

final class H264MirrorView: MirrorCanvasView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let mediaQueue = DispatchQueue(label: "com.zhuzhanxuan.phonemirror.h264", qos: .userInteractive)
    private var formatDescription: CMVideoFormatDescription?
    private var pendingSPS: Data?
    private var pendingPPS: Data?
    private var configuredSPS: Data?
    private var configuredPPS: Data?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
    }

    func enqueueH264(_ payload: Data, pts: UInt64) {
        mediaQueue.async { [weak self] in
            autoreleasepool { self?.processH264(payload, pts: pts) }
        }
    }

    func resetDecoder() {
        mediaQueue.async { [weak self] in
            guard let self else { return }
            formatDescription = nil
            pendingSPS = nil
            pendingPPS = nil
            configuredSPS = nil
            configuredPPS = nil
            DispatchQueue.main.async { self.displayLayer.flushAndRemoveImage() }
        }
    }

    private func processH264(_ payload: Data, pts: UInt64) {
        let nalUnits = splitNALUnits(payload)
        if let sps = nalUnits.first(where: { ($0.first ?? 0) & 0x1F == 7 }) { pendingSPS = sps }
        if let pps = nalUnits.first(where: { ($0.first ?? 0) & 0x1F == 8 }) { pendingPPS = pps }
        if let sps = pendingSPS, let pps = pendingPPS,
           formatDescription == nil || sps != configuredSPS || pps != configuredPPS {
            createFormatDescription(sps: sps, pps: pps)
        } else if payload.first == 1 {
            parseAVCConfiguration(payload)
        }

        guard let formatDescription else { return }
        let frameNALs = nalUnits.filter {
            let type = ($0.first ?? 0) & 0x1F
            return type != 7 && type != 8
        }
        guard !frameNALs.isEmpty else { return }
        var avcc = Data()
        frameNALs.forEach { avcc.appendBigEndian(UInt32($0.count)); avcc.append($0) }
        guard let sample = makeSample(data: avcc, format: formatDescription, pts: pts) else { return }
        if displayLayer.status == .failed { displayLayer.flushAndRemoveImage() }
        if displayLayer.isReadyForMoreMediaData { displayLayer.enqueue(sample) }
    }

    private func createFormatDescription(sps: Data, pps: Data) {
        sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                guard let spsAddress = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                      let ppsAddress = ppsBytes.bindMemory(to: UInt8.self).baseAddress else { return }
                let pointers = [spsAddress, ppsAddress]
                let sizes = [sps.count, pps.count]
                var description: CMFormatDescription?
                if CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description
                ) == noErr, let description {
                    formatDescription = description
                    configuredSPS = sps
                    configuredPPS = pps
                }
            }
        }
    }

    private func parseAVCConfiguration(_ data: Data) {
        guard data.count > 7 else { return }
        let spsCount = Int(data[5] & 0x1F)
        var offset = 6; var sps: Data?
        for _ in 0..<spsCount {
            guard offset + 2 <= data.count else { return }
            let length = Int(data.readUInt16(at: offset)); offset += 2
            guard offset + length <= data.count else { return }
            sps = Data(data[offset..<(offset + length)]); offset += length
        }
        guard offset < data.count else { return }
        let ppsCount = Int(data[offset]); offset += 1; var pps: Data?
        for _ in 0..<ppsCount {
            guard offset + 2 <= data.count else { return }
            let length = Int(data.readUInt16(at: offset)); offset += 2
            guard offset + length <= data.count else { return }
            pps = Data(data[offset..<(offset + length)]); offset += length
        }
        if let sps, let pps { createFormatDescription(sps: sps, pps: pps) }
    }

    private func makeSample(data: Data, format: CMFormatDescription, pts: UInt64) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let status = data.withUnsafeBytes { bytes in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: data.count, flags: 0, blockBufferOut: &block
            ).flatMapStatus {
                guard let base = bytes.baseAddress, let block else { return -1 }
                return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block,
                                                      offsetIntoDestination: 0, dataLength: data.count)
            }
        }
        guard status == noErr, let block else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(pts), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var size = data.count; var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    private func splitNALUnits(_ data: Data) -> [Data] {
        var starts: [(Int, Int)] = []; var index = 0
        while index + 3 < data.count {
            if data[index] == 0, data[index + 1] == 0, data[index + 2] == 1 {
                starts.append((index, 3)); index += 3
            } else if index + 4 <= data.count, data[index] == 0, data[index + 1] == 0,
                      data[index + 2] == 0, data[index + 3] == 1 {
                starts.append((index, 4)); index += 4
            } else { index += 1 }
        }
        if starts.isEmpty {
            var result: [Data] = []; var offset = 0
            while offset + 4 <= data.count {
                let length = Int(data.readUInt32(at: offset)); offset += 4
                guard length > 0, offset + length <= data.count else { return [data] }
                result.append(Data(data[offset..<(offset + length)])); offset += length
            }
            return result.isEmpty ? [data] : result
        }
        return starts.enumerated().compactMap { position, value in
            let begin = value.0 + value.1
            let end = position + 1 < starts.count ? starts[position + 1].0 : data.count
            return begin < end ? Data(data[begin..<end]) : nil
        }
    }
}

private extension OSStatus {
    func flatMapStatus(_ body: () -> OSStatus) -> OSStatus { self == noErr ? body() : self }
}
