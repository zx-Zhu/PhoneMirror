import AppKit
import Foundation
import SwiftUI

@MainActor
final class MirrorStore: ObservableObject {
    @Published private(set) var devices: [MirrorDevice] = []
    @Published var selectedDeviceID: String?
    @Published private(set) var details = DeviceDetails()
    @Published private(set) var displaySize = CGSize(width: 1260, height: 2720)
    @Published private(set) var image: NSImage?
    @Published private(set) var state: MirrorState = .idle
    @Published private(set) var fps = 0.0
    @Published private(set) var latency = 0.0
    @Published private(set) var frameCount = 0
    @Published private(set) var hdcPath: String?
    @Published private(set) var recordingState: SystemRecordingState = .idle
    @Published private(set) var recordingElapsed: TimeInterval = 0
    @Published private(set) var clipboardMessage: String?
    @Published private(set) var adbPath: String?
    @Published private(set) var iosPath: String?
    @Published private(set) var harmonyRealtimeTouch = false
    @Published private(set) var harmonyH264Active = false
    @Published private(set) var iosCaptureActive = false
    @Published private(set) var iosCameraPermissionNeedsSettings = false
    @Published private(set) var packageInstallState: PackageInstallState = .idle
    let h264Video = H264FrameBus()
    let iosCapture: IOSCaptureClient
    @Published var quality: StreamQuality = .balanced {
        didSet {
            UserDefaults.standard.set(quality.rawValue, forKey: "streamQuality")
            if oldValue != quality, selectedPlatform == .android, requestedStreaming { startStreaming() }
        }
    }
    @Published var alwaysOnTop = false

    private let client: HDCClient
    private let adbClient: ADBClient
    private let iosClient: IOSClient
    private var discoveryTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var frameTimes: [Date] = []
    private var consecutiveFailures = 0
    private var requestedStreaming = false
    private var hasStarted = false
    private var inputQueue: [PendingInput] = []
    private var inputDrainTask: Task<Void, Never>?
    private var recordingTimerTask: Task<Void, Never>?
    private var clipboardMessageTask: Task<Void, Never>?
    private var packageInstallTask: Task<Void, Never>?
    private var packageInstallResetTask: Task<Void, Never>?
    private var recordingFilename: String?
    private var recordingDeviceID: String?
    private var recordingStartedAt: Date?
    private var recordingLocalURL: URL?
    private var streamGeneration = UUID()

    init(
        client: HDCClient = .shared, adbClient: ADBClient = .shared,
        iosClient: IOSClient = .shared, iosCapture: IOSCaptureClient? = nil
    ) {
        self.client = client
        self.adbClient = adbClient
        self.iosClient = iosClient
        self.iosCapture = iosCapture ?? .shared
        Self.migrateLegacyPreferencesIfNeeded()
        if let rawQuality = UserDefaults.standard.string(forKey: "streamQuality"),
           let storedQuality = StreamQuality(rawValue: rawQuality) {
            quality = storedQuality
        }
    }

    deinit {
        discoveryTask?.cancel()
        streamTask?.cancel()
        recordingTimerTask?.cancel()
        clipboardMessageTask?.cancel()
        packageInstallTask?.cancel()
        packageInstallResetTask?.cancel()
    }

    var selectedPlatform: DevicePlatform? {
        selectedDevice?.platform
    }

    var usesH264Stream: Bool { selectedPlatform == .android || harmonyH264Active }
    var usesIOSCapture: Bool { selectedPlatform == .ios && iosCaptureActive }
    var hasDisplaySurface: Bool { image != nil || usesH264Stream || usesIOSCapture }

    var availableToolsLabel: String {
        let tools = [(hdcPath != nil, "HDC"), (adbPath != nil, "ADB"), (iosPath != nil, "iOS")]
            .compactMap { $0.0 ? $0.1 : nil }
        return tools.isEmpty ? "未找到设备连接工具" : tools.joined(separator: " · ") + " 已就绪"
    }

    var selectedDevice: MirrorDevice? {
        devices.first(where: { $0.id == selectedDeviceID })
    }

    var isStreaming: Bool { state == .streaming || state == .connecting }
    var isSystemRecording: Bool { recordingState.isRecording }
    var acceptsPackageDrop: Bool { selectedPlatform == .android || selectedPlatform == .harmonyOS }

    var recordingTimeLabel: String {
        let seconds = max(0, Int(recordingElapsed.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var statusDetail: String {
        switch state {
        case .idle:
            if hdcPath == nil && adbPath == nil && iosPath == nil { return "未找到设备连接工具" }
            return devices.isEmpty ? "连接手机并开启 USB 调试" : "选择设备后开始投屏"
        case .connecting: return "正在从手机读取第一帧…"
        case .streaming:
            if usesIOSCapture { return String(format: "%.1f FPS · iOS USB 只读", fps) }
            return usesH264Stream
                ? String(format: "%.1f FPS · H.264", fps)
                : String(format: "%.1f FPS · 截图流 · %.0f ms", fps, latency * 1_000)
        case .paused: return selectedPlatform == .ios ? "画面已暂停" : "画面暂停，控制仍可使用"
        case .failed(let message): return message
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            self.hdcPath = await self.client.executablePath
            self.adbPath = await self.adbClient.executablePath
            self.iosPath = await self.iosClient.executablePath
            while !Task.isCancelled {
                await self.refreshDevices()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refreshDevices() async {
        let retainedIOSDevice = selectedDevice.flatMap { device in
            device.platform == .ios && requestedStreaming
                && (state == .connecting || iosCaptureActive) ? device : nil
        }
        async let harmonyDevices = client.listDevices()
        async let androidDevices = adbClient.listDevices()
        async let iosDevices = iosClient.listDevices()
        var latest = await harmonyDevices + androidDevices + iosDevices
        // CoreMediaIO temporarily owns the QuickTime USB configuration while
        // capturing. usbmux may hide the same device during that period even
        // though video is healthy, so retain it until capture actually stops.
        if let retainedIOSDevice, !latest.contains(where: { $0.id == retainedIOSDevice.id }) {
            latest.append(retainedIOSDevice)
        }
        let connected = latest.filter(\.state.isConnected)
        devices = latest.filter { $0.state != .offline }

        if let selectedDeviceID, connected.contains(where: { $0.id == selectedDeviceID }) {
            if selectedPlatform == .ios, requestedStreaming, !isStreaming {
                startStreaming()
            }
            return
        }

        let rememberedID = UserDefaults.standard.string(forKey: "selectedDeviceID")
        if let preferred = connected.first(where: { $0.id == rememberedID }) ?? connected.first {
            await selectDevice(preferred.id, autoStart: image == nil || requestedStreaming)
        } else {
            selectedDeviceID = nil
            if requestedStreaming {
                streamTask?.cancel()
                streamTask = nil
                state = .failed("设备已断开，重新连接后会自动恢复")
            } else if image == nil {
                state = .idle
            }
        }
    }

    func selectDevice(_ id: String, autoStart: Bool = true) async {
        guard selectedDeviceID != id || details.model == "HarmonyOS 设备" else {
            if autoStart && !isStreaming { startStreaming() }
            return
        }
        let previousDevice = selectedDevice
        let shouldResume = requestedStreaming
        streamGeneration = UUID()
        streamTask?.cancel()
        streamTask = nil
        if let previousDevice {
            switch previousDevice.platform {
            case .android: await adbClient.stopStream(deviceID: previousDevice.serial)
            case .harmonyOS:
                await client.stopHarmonyStream(deviceID: previousDevice.serial)
                await client.stopRealtimeTouch(deviceID: previousDevice.serial)
            case .ios:
                await iosCapture.stop()
            }
        }
        requestedStreaming = shouldResume
        selectedDeviceID = id
        UserDefaults.standard.set(id, forKey: "selectedDeviceID")
        guard let device = devices.first(where: { $0.id == id }) else { return }
        image = nil
        harmonyH264Active = false
        iosCaptureActive = false
        iosCameraPermissionNeedsSettings = false
        h264Video.reset()
        switch device.platform {
        case .harmonyOS:
            details = await client.details(for: device.serial)
            harmonyRealtimeTouch = await client.prepareRealtimeTouch(deviceID: device.serial)
        case .android: details = await adbClient.details(for: device)
        case .ios:
            details = await iosClient.details(for: device)
            iosCameraPermissionNeedsSettings = iosCapture.cameraPermissionNeedsSettings
        }
        displaySize = details.resolution
        consecutiveFailures = 0
        if autoStart, device.platform != .ios || shouldResume { startStreaming() }
    }

    func toggleStreaming() {
        switch state {
        case .streaming, .connecting:
            requestedStreaming = false
            streamTask?.cancel()
            streamTask = nil
            if let device = selectedDevice {
                Task {
                    switch device.platform {
                    case .android: await adbClient.stopStream(deviceID: device.serial)
                    case .harmonyOS: await client.stopHarmonyStream(deviceID: device.serial)
                    case .ios:
                        await iosCapture.stop()
                        self.iosCaptureActive = false
                    }
                }
            }
            state = .paused
        case .paused, .idle, .failed:
            startStreaming()
        }
    }

    func requestIOSCameraPermission() {
        guard selectedPlatform == .ios else { return }
        Task { [weak self] in
            guard let self else { return }
            let allowed = await self.iosCapture.requestCameraAccessOrOpenSettings()
            self.iosCameraPermissionNeedsSettings = !allowed
            if allowed, let device = self.selectedDevice {
                self.startIOSStreaming(device)
            }
        }
    }

    func shutdown() {
        discoveryTask?.cancel()
        streamTask?.cancel()
        inputDrainTask?.cancel()
        iosCapture.shutdownSynchronously()
    }

    func refreshIOSPermissionAfterActivation() {
        guard selectedPlatform == .ios else { return }
        let status = iosCapture.cameraAuthorizationStatus
        iosCameraPermissionNeedsSettings = status == .denied || status == .restricted
        if status == .authorized, requestedStreaming, state != .streaming {
            iosCapture.refreshDevices()
            startStreaming()
        }
    }

    func startStreaming() {
        guard let device = selectedDevice else {
            state = .failed("没有可用设备")
            return
        }
        if device.platform == .android {
            startAndroidStreaming(device)
            return
        }
        if device.platform == .ios {
            startIOSStreaming(device)
            return
        }
        startHarmonyStreaming(device)
    }

    func stopStreaming(keepIntent: Bool = false) {
        streamGeneration = UUID()
        requestedStreaming = keepIntent
        streamTask?.cancel()
        streamTask = nil
        if let device = selectedDevice {
            Task {
                switch device.platform {
                case .android: await adbClient.stopStream(deviceID: device.serial)
                case .harmonyOS: await client.stopHarmonyStream(deviceID: device.serial)
                case .ios:
                    await iosCapture.stop()
                }
            }
        }
        if !keepIntent { state = image == nil && selectedPlatform != .android ? .idle : .paused }
    }

    func send(_ command: RemoteCommand) {
        guard let device = selectedDevice, device.platform != .ios else { return }
        let resolution = device.platform == .harmonyOS ? details.resolution : displaySize
        let item = PendingInput(device: device, resolution: resolution, command: command)
        if case .touchMove = command, let last = inputQueue.indices.last, case .touchMove = inputQueue[last].command {
            inputQueue[last] = item
        } else if case .scroll(let point, let dx, let dy) = command,
                  let last = inputQueue.indices.last,
                  case .scroll(_, let previousX, let previousY) = inputQueue[last].command {
            inputQueue[last] = PendingInput(
                device: device, resolution: resolution,
                command: .scroll(at: point, deltaX: previousX + dx, deltaY: previousY + dy)
            )
        } else {
            inputQueue.append(item)
        }
        guard inputDrainTask == nil else { return }
        inputDrainTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.inputQueue.isEmpty {
                let pending = self.inputQueue.removeFirst()
                switch pending.device.platform {
                case .harmonyOS:
                    let sent = await self.client.send(pending.command, to: pending.device.serial, resolution: pending.resolution)
                    if !sent {
                        self.harmonyRealtimeTouch = false
                        await self.sendHarmonyFallback(pending)
                    }
                case .android:
                    _ = await self.adbClient.send(pending.command, to: pending.device.serial, resolution: pending.resolution)
                case .ios:
                    break
                }
            }
            self.inputDrainTask = nil
        }
    }

    func installPackage(at url: URL) {
        guard let device = selectedDevice, device.state.isConnected else {
            packageInstallState = .failed("设备未连接，无法安装")
            scheduleInstallStateReset()
            return
        }
        guard device.platform == .android || device.platform == .harmonyOS else {
            packageInstallState = .failed("iOS 只读投屏不支持安装应用")
            scheduleInstallStateReset()
            return
        }
        let expectedExtension = device.platform == .android ? "apk" : "hap"
        guard url.isFileURL,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              url.pathExtension.lowercased() == expectedExtension else {
            packageInstallState = .failed("请拖入 .\(expectedExtension) 安装包")
            scheduleInstallStateReset()
            return
        }
        guard !packageInstallState.isInstalling else { return }

        packageInstallTask?.cancel()
        packageInstallResetTask?.cancel()
        packageInstallState = .installing(url.lastPathComponent)
        packageInstallTask = Task { [weak self] in
            guard let self else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let info: AppPackageInfo
                switch device.platform {
                case .android:
                    info = try await self.adbClient.installAndLaunch(packageURL: url, deviceID: device.serial)
                case .harmonyOS:
                    info = try await self.client.installAndLaunch(packageURL: url, deviceID: device.serial)
                case .ios:
                    return
                }
                guard !Task.isCancelled, self.selectedDeviceID == device.id else { return }
                self.packageInstallState = .succeeded(info.identifier)
            } catch {
                guard !Task.isCancelled else { return }
                self.packageInstallState = .failed("安装失败：\(error.localizedDescription)")
            }
            self.scheduleInstallStateReset()
        }
    }

    func copyScreenshotToClipboard() {
        guard let device = selectedDevice else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let source: NSImage
                if device.platform == .android {
                    let data = try await self.adbClient.capture(deviceID: device.serial)
                    guard let decoded = NSImage(data: data) else { throw ClipboardFileError.imageEncodingFailed }
                    source = decoded
                } else if device.platform == .harmonyOS {
                    let frame = try await self.client.capture(deviceID: device.serial, quality: .original)
                    guard let decoded = NSImage(data: frame.data) else { throw ClipboardFileError.imageEncodingFailed }
                    source = decoded
                } else {
                    if self.iosCaptureActive {
                        source = try self.iosCapture.snapshot()
                    } else {
                        let data = try await self.iosClient.capture(deviceID: device.serial)
                        guard let decoded = NSImage(data: data) else { throw ClipboardFileError.imageEncodingFailed }
                        source = decoded
                    }
                }
                let url = try ClipboardFileStore.writePNG(source)
                guard ClipboardFileStore.copyFile(url) else { throw ClipboardFileError.clipboardWriteFailed }
                self.showClipboardMessage("截图文件已复制，可直接粘贴")
            } catch {
                self.showClipboardMessage(error.localizedDescription)
            }
        }
    }

    func toggleSystemRecording() {
        guard recordingState.canToggle else { return }
        if recordingState == .recording {
            stopSystemRecording()
        } else {
            startSystemRecording()
        }
    }

    private func startSystemRecording() {
        guard let device = selectedDevice else {
            recordingState = .failed("没有可用设备")
            showClipboardMessage("没有可用设备")
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let filename = "PhoneMirror_\(formatter.string(from: Date())).mp4"
        recordingState = .starting
        recordingDeviceID = device.id
        recordingFilename = filename
        recordingLocalURL = nil
        recordingElapsed = 0

        Task { [weak self] in
            guard let self else { return }
            do {
                switch device.platform {
                case .harmonyOS:
                    try await self.client.startSystemRecording(deviceID: device.serial, filename: filename)
                case .android:
                    try await self.adbClient.startSystemRecording(
                        deviceID: device.serial,
                        remotePath: self.androidRecordingPath(filename),
                        resolution: self.details.resolution
                    )
                case .ios:
                    let url = try ClipboardFileStore.makeArtifactURL(
                        prefix: "PhoneMirror_Recording", extension: "mov"
                    )
                    self.recordingLocalURL = url
                    try await self.iosCapture.startRecording(to: url)
                }
                guard self.recordingFilename == filename else { return }
                self.recordingStartedAt = Date()
                self.recordingState = .recording
                self.startRecordingTimer()
            } catch {
                self.clearRecordingSession()
                self.recordingState = .failed(error.localizedDescription)
                self.showClipboardMessage("录屏启动失败：\(error.localizedDescription)")
            }
        }
    }

    private func stopSystemRecording() {
        guard let deviceID = recordingDeviceID, let filename = recordingFilename,
              let device = devices.first(where: { $0.id == deviceID }) else {
            clearRecordingSession()
            recordingState = .idle
            return
        }
        recordingState = .stopping
        recordingTimerTask?.cancel()
        recordingTimerTask = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                let destination: URL
                if let recordingLocalURL = self.recordingLocalURL {
                    destination = recordingLocalURL
                } else {
                    destination = try ClipboardFileStore.makeArtifactURL(
                        prefix: "PhoneMirror_Recording", extension: "mp4"
                    )
                }
                switch device.platform {
                case .harmonyOS:
                    _ = try await self.client.stopSystemRecordingAndReceive(
                        deviceID: device.serial, filename: filename, destination: destination
                    )
                case .android:
                    try await self.adbClient.stopSystemRecordingAndReceive(
                        deviceID: device.serial, remotePath: self.androidRecordingPath(filename), destination: destination
                    )
                case .ios:
                    try await self.iosCapture.stopRecording()
                }
                guard ClipboardFileStore.copyFile(destination) else { throw ClipboardFileError.clipboardWriteFailed }
                self.clearRecordingSession()
                self.recordingState = .idle
                self.showClipboardMessage("录屏文件已复制，可直接粘贴")
            } catch {
                self.clearRecordingSession()
                self.recordingState = .failed(error.localizedDescription)
                self.showClipboardMessage("录屏导出失败：\(error.localizedDescription)")
            }
        }
    }

    private func startRecordingTimer() {
        recordingTimerTask?.cancel()
        recordingTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let startedAt = self.recordingStartedAt else { return }
                self.recordingElapsed = Date().timeIntervalSince(startedAt)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func clearRecordingSession() {
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        recordingFilename = nil
        recordingDeviceID = nil
        recordingStartedAt = nil
        recordingLocalURL = nil
        recordingElapsed = 0
    }

    private func showClipboardMessage(_ message: String) {
        clipboardMessageTask?.cancel()
        clipboardMessage = message
        clipboardMessageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.clipboardMessage = nil
        }
    }

    private func scheduleInstallStateReset() {
        packageInstallResetTask?.cancel()
        packageInstallResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.packageInstallState = .idle
            self?.packageInstallResetTask = nil
        }
    }

    private func startAndroidStreaming(_ device: MirrorDevice) {
        requestedStreaming = true
        streamTask?.cancel()
        let generation = UUID()
        streamGeneration = generation
        let videoBus = h264Video
        streamTask = Task { [weak self] in
            guard let self else { return }
            self.state = .connecting
            do {
                try await self.adbClient.startStream(
                    deviceID: device.serial,
                    quality: self.quality,
                    onH264: { [weak self] data, pts, isFrame in
                        videoBus.deliver(data: data, presentationTime: pts)
                        if isFrame, let measuredFPS = videoBus.noteFrame() {
                            Task { @MainActor in
                                guard let self, self.selectedDeviceID == device.id else { return }
                                self.frameCount += 1
                                self.state = .streaming
                                self.fps = measuredFPS
                            }
                        }
                    },
                    onVideoSize: { [weak self] width, height in
                        Task { @MainActor in
                            guard let self, self.selectedDeviceID == device.id else { return }
                            self.displaySize = CGSize(width: width, height: height)
                            let videoIsLandscape = width > height
                            let deviceIsLandscape = self.details.resolution.width > self.details.resolution.height
                            if videoIsLandscape != deviceIsLandscape {
                                self.details.resolution = CGSize(
                                    width: self.details.resolution.height,
                                    height: self.details.resolution.width
                                )
                            }
                        }
                    },
                    onExit: { [weak self] in
                        Task { @MainActor in
                            guard let self, self.selectedDeviceID == device.id,
                                  self.requestedStreaming, self.streamGeneration == generation else { return }
                            self.state = .failed("Android 视频通道已断开，正在等待恢复")
                            try? await Task.sleep(for: .seconds(1))
                            guard self.selectedDeviceID == device.id, self.requestedStreaming,
                                  self.streamGeneration == generation else { return }
                            self.startAndroidStreaming(device)
                        }
                    }
                )
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func startHarmonyStreaming(_ device: MirrorDevice) {
        requestedStreaming = true
        streamTask?.cancel()
        let generation = UUID()
        streamGeneration = generation
        harmonyH264Active = true
        image = nil
        h264Video.reset()
        let videoBus = h264Video
        streamTask = Task { [weak self] in
            guard let self else { return }
            self.state = .connecting
            do {
                try await self.client.startHarmonyStream(
                    deviceID: device.serial,
                    onH264: { [weak self] data, pts, isFrame in
                        videoBus.deliver(data: data, presentationTime: pts)
                        if isFrame, let measuredFPS = videoBus.noteFrame() {
                            Task { @MainActor in
                                guard let self, self.selectedDeviceID == device.id,
                                      self.streamGeneration == generation else { return }
                                self.frameCount += 1
                                self.state = .streaming
                                self.fps = measuredFPS
                            }
                        }
                    },
                    onExit: { [weak self] in
                        Task { @MainActor in
                            guard let self, self.selectedDeviceID == device.id, self.requestedStreaming,
                                  self.streamGeneration == generation else { return }
                            self.state = .failed("HarmonyOS H.264 通道已断开，正在重连")
                            try? await Task.sleep(for: .seconds(1))
                            guard self.selectedDeviceID == device.id, self.requestedStreaming,
                                  self.streamGeneration == generation else { return }
                            self.startHarmonyStreaming(device)
                        }
                    }
                )
                try? await Task.sleep(for: .seconds(8))
                guard self.selectedDeviceID == device.id, self.requestedStreaming,
                      self.streamGeneration == generation, self.state == .connecting else { return }
                let fallbackGeneration = UUID()
                self.streamGeneration = fallbackGeneration
                await self.client.stopHarmonyStream(deviceID: device.serial)
                self.harmonyH264Active = false
                self.h264Video.reset()
                await self.runHarmonySnapshotFallback(device: device, generation: fallbackGeneration)
            } catch {
                guard self.selectedDeviceID == device.id, self.requestedStreaming,
                      self.streamGeneration == generation else { return }
                let fallbackGeneration = UUID()
                self.streamGeneration = fallbackGeneration
                self.harmonyH264Active = false
                self.h264Video.reset()
                await self.runHarmonySnapshotFallback(device: device, generation: fallbackGeneration)
            }
        }
    }

    private func startIOSStreaming(_ device: MirrorDevice) {
        requestedStreaming = true
        streamTask?.cancel()
        let generation = UUID()
        streamGeneration = generation
        iosCaptureActive = true
        image = nil
        frameTimes.removeAll()
        streamTask = Task { [weak self] in
            guard let self else { return }
            self.state = .connecting
            do {
                try await self.iosCapture.start(
                    serial: device.serial,
                    onFirstFrame: { [weak self] size in
                        Task { @MainActor in
                            guard let self, self.selectedDeviceID == device.id,
                                  self.streamGeneration == generation else { return }
                            self.displaySize = size
                            self.details.resolution = size
                            self.state = .streaming
                        }
                    },
                    onFrame: { [weak self] size in
                        Task { @MainActor in
                            guard let self, self.selectedDeviceID == device.id,
                                  self.streamGeneration == generation else { return }
                            if self.displaySize != size {
                                self.displaySize = size
                                self.details.resolution = size
                            }
                            self.frameCount += 1
                            self.recordFrame(at: Date())
                            self.state = .streaming
                        }
                    }
                )
                try? await Task.sleep(for: .seconds(10))
                guard self.selectedDeviceID == device.id, self.streamGeneration == generation,
                      self.requestedStreaming, self.state == .connecting else { return }
                self.state = .failed("未收到 iPhone 画面，请解锁手机并允许相机访问")
            } catch {
                guard self.selectedDeviceID == device.id, self.streamGeneration == generation else { return }
                self.iosCaptureActive = false
                self.iosCameraPermissionNeedsSettings = self.iosCapture.cameraPermissionNeedsSettings
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func runHarmonySnapshotFallback(device: MirrorDevice, generation: UUID) async {
        let deviceID = device.serial
        state = .connecting
        while !Task.isCancelled, requestedStreaming, selectedDeviceID == device.id, streamGeneration == generation {
            let loopStart = Date()
            do {
                let frame = try await client.capture(deviceID: deviceID, quality: quality)
                guard !Task.isCancelled, let decoded = NSImage(data: frame.data) else { continue }
                image = decoded
                if let sourceResolution = frame.sourceResolution, sourceResolution != details.resolution {
                    details.resolution = sourceResolution
                    displaySize = sourceResolution
                }
                latency = frame.latency
                frameCount += 1
                consecutiveFailures = 0
                state = .streaming
                recordFrame(at: Date())
            } catch {
                consecutiveFailures += 1
                if consecutiveFailures >= 2 { state = .failed(error.localizedDescription) }
                try? await Task.sleep(for: .milliseconds(600))
            }

            let remaining = quality.preferredFrameInterval - Date().timeIntervalSince(loopStart)
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
        }
        await client.removeCaptureArtifact(deviceID: deviceID)
    }

    private func androidRecordingPath(_ filename: String) -> String {
        "/sdcard/Movies/\(filename)"
    }

    private func sendHarmonyFallback(_ pending: PendingInput) async {
        switch pending.command {
        case .touchUp(let point):
            _ = await client.send(.tap(point), to: pending.device.serial, resolution: pending.resolution)
        case .touchDown, .touchMove:
            break
        case .scroll(let point, _, let deltaY):
            let distance = min(0.22, max(0.06, abs(deltaY) / 500))
            let end = CGPoint(x: point.x, y: (point.y + (deltaY > 0 ? distance : -distance)).clamped01)
            _ = await client.send(.swipe(from: point, to: end, duration: 0.18),
                                  to: pending.device.serial, resolution: pending.resolution)
        default:
            _ = await client.send(pending.command, to: pending.device.serial, resolution: pending.resolution)
        }
    }

    private func recordFrame(at now: Date) {
        frameTimes.append(now)
        frameTimes.removeAll { now.timeIntervalSince($0) > 2 }
        guard frameTimes.count > 1, let first = frameTimes.first else { fps = 0; return }
        fps = Double(frameTimes.count - 1) / max(now.timeIntervalSince(first), 0.01)
    }

    private static func migrateLegacyPreferencesIfNeeded() {
        let current = UserDefaults.standard
        guard current.object(forKey: "didMigrateHarmonyMirrorPreferences") == nil else { return }
        if let legacy = UserDefaults(suiteName: "com.zhuzhanxuan.harmonymirror") {
            for key in ["selectedDeviceID", "streamQuality"] where current.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) { current.set(value, forKey: key) }
            }
        }
        current.set(true, forKey: "didMigrateHarmonyMirrorPreferences")
    }
}

private struct PendingInput {
    let device: MirrorDevice
    let resolution: CGSize
    let command: RemoteCommand
}
