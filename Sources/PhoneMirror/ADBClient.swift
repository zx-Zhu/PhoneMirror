import Foundation
import Network

actor ADBClient {
    static let shared = ADBClient()

    private let executable: URL?
    private let aapt: URL?
    private let streamQueue = DispatchQueue(label: "com.zhuzhanxuan.phonemirror.adb-stream", qos: .userInteractive)
    private var streamProcess: Process?
    private var streamOutput: Pipe?
    private var connection: NWConnection?
    private var controlConnection: NWConnection?
    private var forwardedPort: UInt16?
    private var recordingProcess: Process?
    private var recordingErrorPipe: Pipe?
    private var clipboardSequence: UInt64 = 0

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        executable = Self.findExecutable(environment: environment)
        aapt = Self.findAAPT(environment: environment)
    }

    var executablePath: String? { executable?.path }

    func listDevices() async -> [MirrorDevice] {
        guard let executable else { return [] }
        let result = await CommandRunner.run(executable: executable, arguments: ["devices", "-l"], timeout: 4)
        return MirrorDevice.parseADBList(result.stdout)
    }

    func details(for device: MirrorDevice) async -> DeviceDetails {
        async let model = execute(device.serial, ["shell", "getprop", "ro.product.model"], timeout: 3)
        async let version = execute(device.serial, ["shell", "getprop", "ro.build.version.release"], timeout: 3)
        async let size = execute(device.serial, ["shell", "wm", "size"], timeout: 3)
        let values = await (model, version, size)
        return DeviceDetails(
            model: values.0.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? device.advertisedModel ?? "Android 设备",
            version: "Android " + values.1.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            resolution: Self.parseResolution(values.2.combinedOutput) ?? CGSize(width: 1080, height: 2400)
        )
    }

    func startStream(
        deviceID: String,
        quality: StreamQuality,
        onH264: @escaping @Sendable (Data, UInt64, Bool) -> Void,
        onVideoSize: @escaping @Sendable (Int, Int) -> Void,
        onExit: @escaping @Sendable () -> Void
    ) async throws {
        guard let executable, let server = scrcpyServerURL() else { throw ADBError.scrcpyServerMissing }
        await stopStream(deviceID: deviceID)
        await wakeDevice(deviceID)

        let remote = "/data/local/tmp/scrcpy-server-phonemirror.jar"
        let push = await executeRaw(["-s", deviceID, "push", server.path, remote], timeout: 15)
        guard push.succeeded else { throw ADBError.commandFailed(Self.friendlyError(push)) }
        await removeStaleScrcpyForwards(deviceID: deviceID)

        let port = UInt16(27_183 + Int.random(in: 0...900))
        let forward = await executeRaw(["-s", deviceID, "forward", "tcp:\(port)", "localabstract:scrcpy"], timeout: 5)
        guard forward.succeeded else { throw ADBError.commandFailed(Self.friendlyError(forward)) }
        forwardedPort = port

        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["-s", deviceID, "shell", "CLASSPATH=\(remote)", "app_process", "/",
                             "com.genymobile.scrcpy.Server", "4.0", "tunnel_forward=true",
                             "audio=false", "control=true", "cleanup=false",
                             "send_device_meta=false", "send_dummy_byte=false",
                             "max_size=\(quality.androidMaxSize)", "max_fps=60",
                             "video_bit_rate=\(quality.androidBitRate)"]
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { _ in output.fileHandleForReading.readabilityHandler = nil }
        do {
            try process.run()
            streamProcess = process
            streamOutput = output
        } catch {
            _ = await executeRaw(["-s", deviceID, "forward", "--remove", "tcp:\(port)"], timeout: 3)
            throw ADBError.commandFailed(error.localizedDescription)
        }

        try? await Task.sleep(for: .milliseconds(900))
        guard let networkPort = NWEndpoint.Port(rawValue: port) else { throw ADBError.invalidPort }
        let socket = NWConnection(host: "127.0.0.1", port: networkPort, using: .tcp)
        let exitOnce = CallbackOnce(onExit)
        socket.stateUpdateHandler = { state in
            if case .failed = state { exitOnce.call() }
            if case .cancelled = state { exitOnce.call() }
        }
        connection = socket
        socket.start(queue: streamQueue)
        try? await Task.sleep(for: .milliseconds(150))
        let control = NWConnection(host: "127.0.0.1", port: networkPort, using: .tcp)
        controlConnection = control
        control.start(queue: streamQueue)
        receiveAndDiscardControlResponses(control)
        receive(socket, demuxer: ScrcpyPacketDemuxer(onPacket: onH264, onVideoSize: onVideoSize), onExit: exitOnce)
    }

    func stopStream(deviceID: String?) async {
        connection?.cancel()
        connection = nil
        controlConnection?.cancel()
        controlConnection = nil
        streamOutput?.fileHandleForReading.readabilityHandler = nil
        if let streamProcess, streamProcess.isRunning { streamProcess.terminate() }
        streamProcess = nil
        streamOutput = nil
        if let forwardedPort, let deviceID {
            _ = await executeRaw(["-s", deviceID, "forward", "--remove", "tcp:\(forwardedPort)"], timeout: 3)
        }
        forwardedPort = nil
    }

    func capture(deviceID: String) async throws -> Data {
        let result = await executeData(["-s", deviceID, "exec-out", "screencap", "-p"], timeout: 8)
        guard result.status == 0, result.data.count > 128 else { throw ADBError.commandFailed(result.stderr.nilIfEmpty ?? "Android 截图失败") }
        return result.data
    }

    func installAndLaunch(packageURL: URL, deviceID: String) async throws -> AppPackageInfo {
        guard packageURL.pathExtension.lowercased() == "apk" else { throw ADBError.invalidPackage }
        guard let aapt else { throw ADBError.packageInspectorMissing }
        let metadata = await CommandRunner.run(
            executable: aapt, arguments: ["dump", "badging", packageURL.path], timeout: 15
        )
        guard metadata.succeeded, let info = Self.parsePackageInfo(metadata.stdout) else {
            throw ADBError.invalidPackage
        }
        let install = await executeRaw(["-s", deviceID, "install", "-r", packageURL.path], timeout: 180)
        guard install.succeeded, install.combinedOutput.localizedCaseInsensitiveContains("success") else {
            throw ADBError.commandFailed(Self.friendlyError(install))
        }

        let launch: CommandResult
        if let activity = info.entryPoint {
            launch = await execute(
                deviceID, ["shell", "am", "start", "-W", "-n", "\(info.identifier)/\(activity)"],
                timeout: 15
            )
        } else {
            launch = await execute(
                deviceID, ["shell", "monkey", "-p", info.identifier,
                           "-c", "android.intent.category.LAUNCHER", "1"], timeout: 15
            )
        }
        guard launch.succeeded, !launch.combinedOutput.localizedCaseInsensitiveContains("error") else {
            throw ADBError.commandFailed("APK 已安装，但启动失败：\(Self.friendlyError(launch))")
        }
        return info
    }

    func launchSchema(_ schema: String, deviceID: String) async throws {
        let launch = await execute(deviceID, Self.schemaLaunchArguments(schema), timeout: 15)
        guard launch.succeeded, !Self.outputIndicatesLaunchFailure(launch.combinedOutput) else {
            throw ADBError.commandFailed("Schema 跳转失败：\(Self.friendlyError(launch))")
        }
    }

    static func schemaLaunchArguments(_ schema: String) -> [String] {
        ["shell", "am", "start", "-W", "-a", "android.intent.action.VIEW", "-d", SchemaLink.shellQuoted(schema)]
    }

    static func parsePackageInfo(_ output: String) -> AppPackageInfo? {
        guard let identifier = firstCapture(#"package:\s+name='([^']+)'"#, in: output) else { return nil }
        let activity = firstCapture(#"launchable-activity:\s+name='([^']+)'"#, in: output)
        return AppPackageInfo(identifier: identifier, moduleName: nil, entryPoint: activity)
    }

    func send(_ command: RemoteCommand, to deviceID: String, resolution: CGSize) async -> Bool {
        let arguments: [String]
        switch command {
        case .tap(let point):
            let pixel = Self.pixel(point, resolution: resolution)
            arguments = ["shell", "input", "tap", "\(pixel.x)", "\(pixel.y)"]
        case .swipe(let from, let to, let duration):
            let start = Self.pixel(from, resolution: resolution)
            let end = Self.pixel(to, resolution: resolution)
            arguments = ["shell", "input", "swipe", "\(start.x)", "\(start.y)",
                         "\(end.x)", "\(end.y)", "\(max(50, Int(duration * 1_000)))"]
        case .touchDown(let point):
            return await sendTouch(action: 0, point: point, resolution: resolution)
        case .touchMove(let point):
            return await sendTouch(action: 2, point: point, resolution: resolution)
        case .touchUp(let point):
            return await sendTouch(action: 1, point: point, resolution: resolution)
        case .scroll(let point, let deltaX, let deltaY):
            return await sendScroll(point: point, deltaX: deltaX, deltaY: deltaY, resolution: resolution)
        case .namedKey(let name):
            arguments = ["shell", "input", "keyevent", Self.androidKeyName(name)]
        case .keyCode(let code):
            guard let key = Self.androidKeyCode(code) else { return false }
            arguments = ["shell", "input", "keyevent", key]
        case .keyCombination(let first, let second):
            guard first == 2072, let key = Self.androidLetterKey(second) else { return false }
            arguments = ["shell", "input", "keycombination", "KEYCODE_CTRL_LEFT", key]
        case .text(let text):
            if controlConnection != nil { return await sendClipboardPaste(text) }
            let escaped = text.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: " ", with: "%s")
            arguments = ["shell", "input", "text", escaped]
        }
        return await execute(deviceID, arguments, timeout: 4).succeeded
    }

    func startSystemRecording(deviceID: String, remotePath: String, resolution: CGSize) async throws {
        guard recordingProcess == nil, let executable else { throw ADBError.recordingAlreadyActive }
        await wakeDevice(deviceID)
        let target = Self.encodedSize(resolution)
        let process = Process()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = ["-s", deviceID, "shell", "screenrecord", "--size",
                             "\(Int(target.width))x\(Int(target.height))", "--bit-rate", "8M",
                             "--time-limit", "0", remotePath]
        process.standardOutput = error
        process.standardError = error
        try process.run()
        recordingProcess = process
        recordingErrorPipe = error
    }

    func stopSystemRecordingAndReceive(deviceID: String, remotePath: String, destination: URL) async throws {
        guard let process = recordingProcess else { throw ADBError.noActiveRecording }
        process.interrupt()
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        if process.isRunning { process.terminate() }
        recordingProcess = nil
        recordingErrorPipe = nil
        try? await Task.sleep(for: .milliseconds(350))
        defer { Task { _ = await self.execute(deviceID, ["shell", "rm", "-f", remotePath], timeout: 3) } }
        let receive = await executeRaw(["-s", deviceID, "pull", remotePath, destination.path], timeout: 30)
        guard receive.succeeded else { throw ADBError.commandFailed(Self.friendlyError(receive)) }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 1_024, HDCClient.isMP4File(destination) else { throw ADBError.invalidRecording }
    }

    static func parseResolution(_ output: String) -> CGSize? {
        guard let regex = try? NSRegularExpression(pattern: #"([0-9]{3,5})x([0-9]{3,5})"#) else { return nil }
        let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output))
        guard let match = matches.last,
              let widthRange = Range(match.range(at: 1), in: output),
              let heightRange = Range(match.range(at: 2), in: output),
              let width = Double(output[widthRange]),
              let height = Double(output[heightRange]) else { return nil }
        return CGSize(width: width, height: height)
    }

    static func findExecutable(environment: [String: String]) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb", "/usr/local/bin/adb"
        ]
        if let androidHome = environment["ANDROID_HOME"] {
            candidates.insert(URL(fileURLWithPath: androidHome).appendingPathComponent("platform-tools/adb").path, at: 0)
        }
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("adb").path }
        }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    private static func findAAPT(environment: [String: String]) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var roots = ["\(home)/Library/Android/sdk/build-tools"]
        if let androidHome = environment["ANDROID_HOME"] {
            roots.insert(URL(fileURLWithPath: androidHome).appendingPathComponent("build-tools").path, at: 0)
        }
        for root in roots {
            guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for version in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                let path = URL(fileURLWithPath: root).appendingPathComponent(version).appendingPathComponent("aapt").path
                if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private nonisolated func receive(_ socket: NWConnection, demuxer: ScrcpyPacketDemuxer, onExit: CallbackOnce) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, complete, error in
            if let data, !data.isEmpty { demuxer.consume(data) }
            if complete || error != nil { onExit.call() } else { self?.receive(socket, demuxer: demuxer, onExit: onExit) }
        }
    }

    private nonisolated func receiveAndDiscardControlResponses(_ socket: NWConnection) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] _, _, complete, error in
            guard !complete, error == nil else { return }
            self?.receiveAndDiscardControlResponses(socket)
        }
    }

    private func sendClipboardPaste(_ text: String) async -> Bool {
        guard let controlConnection else { return false }
        var payload = Data(text.utf8)
        if payload.count > 250_000 { payload = Data(payload.prefix(250_000)) }
        clipboardSequence &+= 1
        var message = Data(capacity: 14 + payload.count)
        message.append(9)
        message.appendBigEndian(clipboardSequence)
        message.append(1)
        message.appendBigEndian(UInt32(payload.count))
        message.append(payload)
        return await sendControlMessage(message, over: controlConnection)
    }

    private func sendTouch(action: UInt8, point: CGPoint, resolution: CGSize) async -> Bool {
        guard controlConnection != nil else { return false }
        return await sendControlMessage(Self.touchMessage(action: action, point: point, resolution: resolution))
    }

    static func touchMessage(action: UInt8, point: CGPoint, resolution: CGSize) -> Data {
        let pixel = Self.pixel(point, resolution: resolution)
        var message = Data(capacity: 32)
        message.append(2)
        message.append(action)
        message.appendBigEndian(UInt64.max - 2)
        message.appendBigEndian(UInt32(max(0, pixel.x)))
        message.appendBigEndian(UInt32(max(0, pixel.y)))
        message.appendBigEndian(UInt16(min(65_535, max(1, Int(resolution.width.rounded())))))
        message.appendBigEndian(UInt16(min(65_535, max(1, Int(resolution.height.rounded())))))
        message.appendBigEndian(action == 1 ? UInt16(0) : UInt16.max)
        message.appendBigEndian(UInt32(0))
        message.appendBigEndian(UInt32(0))
        return message
    }

    private func sendScroll(point: CGPoint, deltaX: Double, deltaY: Double, resolution: CGSize) async -> Bool {
        guard controlConnection != nil else { return false }
        return await sendControlMessage(Self.scrollMessage(point: point, deltaX: deltaX, deltaY: deltaY, resolution: resolution))
    }

    static func scrollMessage(point: CGPoint, deltaX: Double, deltaY: Double, resolution: CGSize) -> Data {
        let pixel = Self.pixel(point, resolution: resolution)
        var message = Data(capacity: 21)
        message.append(3)
        message.appendBigEndian(UInt32(max(0, pixel.x)))
        message.appendBigEndian(UInt32(max(0, pixel.y)))
        message.appendBigEndian(UInt16(min(65_535, max(1, Int(resolution.width.rounded())))))
        message.appendBigEndian(UInt16(min(65_535, max(1, Int(resolution.height.rounded())))))
        message.appendBigEndian(Self.fixedPointScroll(deltaX))
        message.appendBigEndian(Self.fixedPointScroll(deltaY))
        message.appendBigEndian(UInt32(0))
        return message
    }

    private func sendControlMessage(_ message: Data) async -> Bool {
        guard let controlConnection else { return false }
        return await sendControlMessage(message, over: controlConnection)
    }

    private func sendControlMessage(_ message: Data, over connection: NWConnection) async -> Bool {
        return await withCheckedContinuation { continuation in
            connection.send(content: message, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    private func scrcpyServerURL() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("scrcpy-server-v4.0"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("third_party/scrcpy-server-v4.0")
        ].compactMap { $0 }
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func execute(_ deviceID: String, _ arguments: [String], timeout: TimeInterval) async -> CommandResult {
        await executeRaw(["-s", deviceID] + arguments, timeout: timeout)
    }

    private func removeStaleScrcpyForwards(deviceID: String) async {
        let existing = await executeRaw(["-s", deviceID, "forward", "--list"], timeout: 4)
        for line in existing.stdout.split(whereSeparator: \.isNewline) where line.hasSuffix(" localabstract:scrcpy") {
            let columns = line.split(whereSeparator: \.isWhitespace)
            if columns.count >= 2 {
                _ = await executeRaw(["-s", deviceID, "forward", "--remove", String(columns[1])], timeout: 3)
            }
        }
    }

    private func wakeDevice(_ deviceID: String) async {
        _ = await execute(deviceID, ["shell", "input", "keyevent", "KEYCODE_WAKEUP"], timeout: 3)
        try? await Task.sleep(for: .milliseconds(350))
    }

    private func executeRaw(_ arguments: [String], timeout: TimeInterval) async -> CommandResult {
        guard let executable else { return CommandResult(status: -1, stdout: "", stderr: "未找到 adb", timedOut: false) }
        return await CommandRunner.run(executable: executable, arguments: arguments, timeout: timeout)
    }

    private func executeData(_ arguments: [String], timeout: TimeInterval) async -> (status: Int32, data: Data, stderr: String) {
        guard let executable else { return (-1, Data(), "未找到 adb") }
        return await Task.detached(priority: .userInitiated) {
            let process = Process(); let output = Pipe(); let error = Pipe()
            process.executableURL = executable; process.arguments = arguments
            process.standardOutput = output; process.standardError = error
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return (process.terminationStatus, data, stderr)
            } catch { return (-1, Data(), error.localizedDescription) }
        }.value
    }

    private static func pixel(_ point: CGPoint, resolution: CGSize) -> (x: Int, y: Int) {
        (Int((point.x.clamped01 * resolution.width).rounded()), Int((point.y.clamped01 * resolution.height).rounded()))
    }

    static func fixedPointScroll(_ delta: Double) -> UInt16 {
        let normalized = min(1, max(-1, delta / 16))
        let signed = Int16((normalized * 32_767).rounded())
        return UInt16(bitPattern: signed)
    }

    private static func encodedSize(_ size: CGSize) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > 1920 else { return size }
        let scale = 1920 / longest
        return CGSize(width: max(8, (size.width * scale / 8).rounded(.down) * 8),
                      height: max(8, (size.height * scale / 8).rounded(.down) * 8))
    }

    private static func androidKeyName(_ name: String) -> String {
        ["Back": "KEYCODE_BACK", "Home": "KEYCODE_HOME", "Power": "KEYCODE_POWER"][name] ?? name
    }

    private static func androidKeyCode(_ code: Int) -> String? {
        [2055: "KEYCODE_DEL", 2071: "KEYCODE_FORWARD_DEL", 2054: "KEYCODE_ENTER", 2049: "KEYCODE_TAB",
         2014: "KEYCODE_DPAD_LEFT", 2015: "KEYCODE_DPAD_RIGHT", 2013: "KEYCODE_DPAD_DOWN",
         2012: "KEYCODE_DPAD_UP", 2210: "KEYCODE_APP_SWITCH"][code]
    }

    private static func androidLetterKey(_ code: Int) -> String? {
        [2017: "KEYCODE_A", 2019: "KEYCODE_C", 2040: "KEYCODE_X", 2042: "KEYCODE_Z"][code]
    }

    private static func friendlyError(_ result: CommandResult) -> String {
        if result.timedOut { return "ADB 响应超时" }
        return result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "ADB 命令执行失败"
    }

    private static func outputIndicatesLaunchFailure(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("error:") || lower.contains("exception")
            || lower.contains("unable to resolve intent")
    }
}

enum ADBError: LocalizedError {
    case commandFailed(String), scrcpyServerMissing, invalidPort, recordingAlreadyActive, noActiveRecording, invalidRecording
    case invalidPackage, packageInspectorMissing
    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): return message
        case .scrcpyServerMissing: return "应用内缺少 scrcpy server"
        case .invalidPort: return "无法创建 Android 视频端口"
        case .recordingAlreadyActive: return "Android 系统录屏已在运行"
        case .noActiveRecording: return "没有正在运行的 Android 录屏"
        case .invalidRecording: return "Android 返回了无效的 MP4 录屏文件"
        case .invalidPackage: return "无法读取 APK 包信息，请确认文件完整"
        case .packageInspectorMissing: return "未找到 Android SDK aapt，无法识别 APK"
        }
    }
}

private extension StreamQuality {
    var androidMaxSize: Int { maxLongEdge ?? 2560 }
    var androidBitRate: Int {
        switch self { case .smooth: return 3_000_000; case .balanced: return 6_000_000; case .sharp: return 10_000_000; case .original: return 16_000_000 }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
