@preconcurrency import AVFoundation
import AppKit
import CoreMediaIO
import OSLog
import SwiftUI

@MainActor
final class IOSCaptureClient: NSObject, ObservableObject {
    static let shared = IOSCaptureClient()
    private static let logger = Logger(subsystem: "com.zhuzhanxuan.phonemirror", category: "iOSCapture")

    @Published private(set) var captureDevices: [AVCaptureDevice] = []
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "com.zhuzhanxuan.phonemirror.ios-capture", qos: .userInteractive)
    private nonisolated let frameBuffer = IOSFrameBuffer()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var currentDeviceID: String?
    private var firstFrameHandler: (@Sendable (CGSize) -> Void)?
    private var frameHandler: (@Sendable (CGSize) -> Void)?
    private var firstFrameDelivered = false
    private var recordingOutput: AVCaptureMovieFileOutput?
    private var recordingDelegate: IOSMovieRecordingDelegate?

    override init() {
        super.init()
    }

    func refreshDevices() {
        Self.enableScreenCaptureDevices()
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.external]
        } else {
            deviceTypes = [.externalUnknown]
        }
        captureDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes, mediaType: .muxed, position: .unspecified
        ).devices
        Self.logger.info("iOS muxed capture devices: \(self.captureDevices.count, privacy: .public)")
    }

    var cameraAuthorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    var canStartWithoutPrompt: Bool { cameraAuthorizationStatus == .authorized }

    var cameraPermissionNeedsSettings: Bool {
        cameraAuthorizationStatus == .denied || cameraAuthorizationStatus == .restricted
    }

    var isRunning: Bool { session.isRunning }

    func requestCameraAccessOrOpenSettings() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            NSApp.activate(ignoringOtherApps: true)
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else {
                return false
            }
            NSWorkspace.shared.open(url)
            return false
        @unknown default:
            return false
        }
    }

    func uniqueID(for serial: String) -> String? {
        let normalized = serial.replacingOccurrences(of: "-", with: "").lowercased()
        return captureDevices.first { device in
            let identifier = device.uniqueID.replacingOccurrences(of: "-", with: "").lowercased()
            return identifier.contains(normalized) || normalized.contains(identifier)
        }?.uniqueID ?? (captureDevices.count == 1 ? captureDevices[0].uniqueID : nil)
    }

    func start(
        serial: String,
        onFirstFrame: @escaping @Sendable (CGSize) -> Void,
        onFrame: @escaping @Sendable (CGSize) -> Void
    ) async throws {
        await stop()
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true
        case .notDetermined:
            NSApp.activate(ignoringOtherApps: true)
            authorized = await AVCaptureDevice.requestAccess(for: .video)
        default: authorized = false
        }
        Self.logger.info("iOS capture authorization: \(authorized, privacy: .public)")
        guard authorized else { throw IOSCaptureError.cameraPermission }
        // Enumerating this CoreMediaIO source can switch the phone's USB
        // configuration. Do it only after an explicit start request.
        refreshDevices()
        guard let uniqueID = uniqueID(for: serial), let device = AVCaptureDevice(uniqueID: uniqueID) else {
            throw IOSCaptureError.captureDeviceUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        firstFrameHandler = onFirstFrame
        frameHandler = onFrame
        firstFrameDelivered = false
        currentDeviceID = uniqueID
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = nil
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)

        session.beginConfiguration()
        session.sessionPreset = .high
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        guard session.canAddInput(input), session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            throw IOSCaptureError.configurationFailed
        }
        session.addInput(input)
        session.addOutput(videoOutput)
        session.commitConfiguration()
        let captureSession = session
        captureQueue.async { if !captureSession.isRunning { captureSession.startRunning() } }
        Self.logger.info("Starting iOS capture device: \(device.localizedName, privacy: .public)")
    }

    func stop() async {
        let captureSession = session
        let output = videoOutput
        await withCheckedContinuation { continuation in
            captureQueue.async {
                if captureSession.isRunning { captureSession.stopRunning() }
                output.setSampleBufferDelegate(nil, queue: nil)
                captureSession.beginConfiguration()
                captureSession.inputs.forEach(captureSession.removeInput)
                captureSession.outputs.forEach(captureSession.removeOutput)
                captureSession.commitConfiguration()
                continuation.resume()
            }
        }
        currentDeviceID = nil
        frameBuffer.reset()
        firstFrameHandler = nil
        frameHandler = nil
        firstFrameDelivered = false
    }

    func shutdownSynchronously() {
        let captureSession = session
        let output = videoOutput
        captureQueue.sync {
            if captureSession.isRunning { captureSession.stopRunning() }
            output.setSampleBufferDelegate(nil, queue: nil)
            captureSession.beginConfiguration()
            captureSession.inputs.forEach(captureSession.removeInput)
            captureSession.outputs.forEach(captureSession.removeOutput)
            captureSession.commitConfiguration()
        }
        currentDeviceID = nil
        frameBuffer.reset()
        firstFrameHandler = nil
        frameHandler = nil
        firstFrameDelivered = false
    }

    func startRecording(to url: URL) async throws {
        guard session.isRunning else { throw IOSCaptureError.captureDeviceUnavailable }
        let output = AVCaptureMovieFileOutput()
        let delegate = IOSMovieRecordingDelegate()
        recordingOutput = output
        recordingDelegate = delegate
        let captureSession = session
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            captureQueue.async {
                captureSession.beginConfiguration()
                guard captureSession.canAddOutput(output) else {
                    captureSession.commitConfiguration()
                    continuation.resume(throwing: IOSCaptureError.configurationFailed)
                    return
                }
                captureSession.addOutput(output)
                captureSession.commitConfiguration()
                output.startRecording(to: url, recordingDelegate: delegate)
                continuation.resume()
            }
        }
    }

    func snapshot() throws -> NSImage {
        guard let pixelBuffer = frameBuffer.current else { throw IOSCaptureError.noFrame }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = imageContext.createCGImage(image, from: image.extent) else {
            throw IOSCaptureError.noFrame
        }
        return NSImage(cgImage: cgImage, size: image.extent.size)
    }

    func stopRecording() async throws {
        guard let output = recordingOutput, let delegate = recordingDelegate else {
            throw IOSCaptureError.noRecording
        }
        let queue = captureQueue
        try await delegate.waitForCompletion { queue.async { output.stopRecording() } }
        let captureSession = session
        await withCheckedContinuation { continuation in
            captureQueue.async {
                captureSession.beginConfiguration()
                captureSession.removeOutput(output)
                captureSession.commitConfiguration()
                continuation.resume()
            }
        }
        recordingOutput = nil
        recordingDelegate = nil
    }

    fileprivate var previewSession: AVCaptureSession { session }

    private static func enableScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allowed: UInt32 = 1
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &allowed
        )
    }
}

extension IOSCaptureClient: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        frameBuffer.store(pixelBuffer)
        let dimensions = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        Task { @MainActor [weak self] in
            guard let self else { return }
            frameHandler?(dimensions)
            if !firstFrameDelivered {
                firstFrameDelivered = true
                Self.logger.info("First iOS frame: \(Int(dimensions.width), privacy: .public)x\(Int(dimensions.height), privacy: .public)")
                firstFrameHandler?(dimensions)
            }
        }
    }
}

private final class IOSFrameBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pixelBuffer: CVPixelBuffer?

    func store(_ value: CVPixelBuffer) {
        lock.withLock { pixelBuffer = value }
    }

    var current: CVPixelBuffer? { lock.withLock { pixelBuffer } }
    func reset() { lock.withLock { pixelBuffer = nil } }
}

private final class IOSMovieRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func waitForCompletion(_ stop: () -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
            stop()
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection], error: Error?
    ) {
        let value: Result<Void, Error> = error.map(Result.failure) ?? .success(())
        lock.lock()
        result = value
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: value)
    }
}

struct IOSMirrorCanvas: NSViewRepresentable {
    @ObservedObject var store: MirrorStore

    func makeNSView(context: Context) -> IOSMirrorView {
        let view = IOSMirrorView()
        view.captureSession = store.iosCapture.previewSession
        return view
    }

    func updateNSView(_ view: IOSMirrorView, context: Context) {
        view.captureSession = store.iosCapture.previewSession
    }
}

final class IOSMirrorView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()

    var captureSession: AVCaptureSession? {
        didSet { previewLayer.session = captureSession }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

enum IOSCaptureError: LocalizedError {
    case cameraPermission, captureDeviceUnavailable, configurationFailed, noRecording, noFrame

    var errorDescription: String? {
        switch self {
        case .cameraPermission: return "请在系统设置 → 隐私与安全性 → 相机中允许 PhoneMirror"
        case .captureDeviceUnavailable: return "未找到 iPhone 屏幕采集源，请解锁手机并信任此 Mac"
        case .configurationFailed: return "无法配置 iPhone USB 视频通道"
        case .noRecording: return "没有正在进行的 iPhone 录屏"
        case .noFrame: return "iPhone 视频通道还没有返回画面"
        }
    }
}
