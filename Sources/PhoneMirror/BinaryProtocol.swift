import Foundation

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    func readUInt16(at offset: Int) -> UInt16 {
        withUnsafeBytes { raw in
            UInt16(bigEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        }
    }

    func readUInt32(at offset: Int) -> UInt32 {
        withUnsafeBytes { raw in
            UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    func readUInt64(at offset: Int) -> UInt64 {
        withUnsafeBytes { raw in
            UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
    }
}

final class CallbackOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?

    init(_ callback: @escaping @Sendable () -> Void) { self.callback = callback }

    func call() {
        lock.lock()
        let value = callback
        callback = nil
        lock.unlock()
        value?()
    }
}

final class ScrcpyPacketDemuxer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var readCodec = false
    private let onPacket: @Sendable (Data, UInt64, Bool) -> Void
    private let onVideoSize: @Sendable (Int, Int) -> Void

    init(
        onPacket: @escaping @Sendable (Data, UInt64, Bool) -> Void,
        onVideoSize: @escaping @Sendable (Int, Int) -> Void
    ) {
        self.onPacket = onPacket
        self.onVideoSize = onVideoSize
    }

    func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var packets: [(Data, UInt64, Bool)] = []
        var sizes: [(Int, Int)] = []

        if !readCodec, buffer.count >= 4 {
            guard buffer.readUInt32(at: 0) == 0x68323634 else {
                buffer.removeAll(keepingCapacity: true)
                lock.unlock()
                return
            }
            buffer.removeSubrange(0..<4)
            readCodec = true
        }

        while readCodec, buffer.count >= 12 {
            let header = buffer.readUInt64(at: 0)
            if header & (1 << 63) != 0 {
                sizes.append((Int(buffer.readUInt32(at: 4)), Int(buffer.readUInt32(at: 8))))
                buffer.removeSubrange(0..<12)
                continue
            }
            let length = Int(buffer.readUInt32(at: 8))
            guard length >= 0, length <= 32 * 1_024 * 1_024 else {
                buffer.removeAll(keepingCapacity: true)
                break
            }
            guard buffer.count >= 12 + length else { break }
            let payload = Data(buffer[12..<(12 + length)])
            let isConfig = header & (1 << 62) != 0
            let pts = header & ((1 << 61) - 1)
            packets.append((payload, pts, !isConfig))
            buffer.removeSubrange(0..<(12 + length))
        }
        lock.unlock()

        sizes.forEach { onVideoSize($0.0, $0.1) }
        packets.forEach { onPacket($0.0, $0.1, $0.2) }
    }
}

/// Decodes the byte stream produced by PhoneMirror Companion. TCP is allowed to
/// split a header or coalesce several packets, so parsing must not assume one
/// receive callback equals one video frame.
final class HarmonyCompanionPacketDemuxer: @unchecked Sendable {
    static let magic: UInt32 = 0x484D434D // HMCM
    static let headerSize = 20
    static let videoPacketType: UInt8 = 1
    static let codecDataFlag: UInt16 = 1 << 3
    static let endOfStreamFlag: UInt16 = 1

    private let lock = NSLock()
    private var buffer = Data()
    private let onVideo: @Sendable (Data, UInt64, Bool) -> Void

    init(onVideo: @escaping @Sendable (Data, UInt64, Bool) -> Void) {
        self.onVideo = onVideo
    }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var videos: [(Data, UInt64, Bool)] = []

        while buffer.count >= Self.headerSize {
            guard buffer.readUInt32(at: 0) == Self.magic, buffer[4] == 1 else {
                // A malformed header means framing has been lost. Discard the
                // buffered bytes so a reconnect starts from a known boundary.
                buffer.removeAll(keepingCapacity: true)
                break
            }
            let type = buffer[5]
            let flags = buffer.readUInt16(at: 6)
            let length = Int(buffer.readUInt32(at: 8))
            guard length <= 64 * 1_024 * 1_024 else {
                buffer.removeAll(keepingCapacity: true)
                break
            }
            guard buffer.count >= Self.headerSize + length else { break }
            let pts = buffer.readUInt64(at: 12)
            let payload = Data(buffer[Self.headerSize..<(Self.headerSize + length)])
            buffer.removeSubrange(0..<(Self.headerSize + length))

            if type == Self.videoPacketType, !payload.isEmpty {
                let isFrame = flags & Self.codecDataFlag == 0 && flags & Self.endOfStreamFlag == 0
                videos.append((payload, pts, isFrame))
            }
        }
        lock.unlock()

        videos.forEach { onVideo($0.0, $0.1, $0.2) }
    }

    var bufferedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }
}

/// Packet format emitted by harmony_cast_bridge.py:
/// UInt32 payload length, UInt8 codec flags, UInt64 PTS, Annex-B H.264 bytes.
final class HarmonyCastingPacketDemuxer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onVideo: @Sendable (Data, UInt64, Bool) -> Void

    init(onVideo: @escaping @Sendable (Data, UInt64, Bool) -> Void) {
        self.onVideo = onVideo
    }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var frames: [(Data, UInt64, Bool)] = []
        while buffer.count >= 4 {
            let length = Int(buffer.readUInt32(at: 0))
            guard length >= 9, length <= 64 * 1_024 * 1_024 else {
                buffer.removeAll(keepingCapacity: true)
                break
            }
            guard buffer.count >= 4 + length else { break }
            let flags = buffer[4]
            let pts = buffer.readUInt64(at: 5)
            let h264 = Data(buffer[13..<(4 + length)])
            buffer.removeSubrange(0..<(4 + length))
            let isFrame = flags & UInt8(HarmonyCompanionPacketDemuxer.codecDataFlag) == 0
                && flags & UInt8(HarmonyCompanionPacketDemuxer.endOfStreamFlag) == 0
            frames.append((h264, pts, isFrame))
        }
        lock.unlock()
        frames.forEach { onVideo($0.0, $0.1, $0.2) }
    }

    var bufferedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }
}
