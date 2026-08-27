import Foundation

actor HDCClient {
    static let shared = HDCClient()

    private let executable: URL?
    private let sessionID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
    private var touchClient: HarmonyTouchClient?
    private var touchDeviceID: String?
    private var videoClient: HarmonyVideoClient?
    private var videoDeviceID: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        executable = Self.findExecutable(environment: environment)
    }

    var isAvailable: Bool { executable != nil }
    var executablePath: String? { executable?.path }

    func listDevices() async -> [MirrorDevice] {
        guard let executable else { return [] }
        let result = await CommandRunner.run(executable: executable, arguments: ["list", "targets", "-v"], timeout: 3)
        return MirrorDevice.parseHDCList(result.stdout)
    }

    func details(for deviceID: String) async -> DeviceDetails {
        async let modelResult = execute(deviceID, ["shell", "param", "get", "const.product.model"], timeout: 3)
        async let versionResult = execute(deviceID, ["shell", "param", "get", "const.product.software.version"], timeout: 3)
        async let displayResult = execute(deviceID, ["shell", "hidumper", "-s", "DisplayManagerService", "-a", "-a"], timeout: 5)
        let (model, version, display) = await (modelResult, versionResult, displayResult)

        var details = DeviceDetails()
        let modelName = model.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let versionName = version.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !modelName.isEmpty { details.model = modelName }
        details.version = versionName
        if let size = Self.parseResolution(display.combinedOutput) { details.resolution = size }
        return details
    }

    func capture(deviceID: String, quality: StreamQuality) async throws -> CapturedFrame {
        let startedAt = Date()
        let suffix = quality == .original ? "png" : "jpeg"
        let remotePath = "/data/local/tmp/phone_mirror_\(sessionID).\(suffix)"
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("harmony-mirror-\(sessionID)-\(UUID().uuidString).\(suffix)")
        defer { try? FileManager.default.removeItem(at: localURL) }

        var captureArguments = ["shell", "snapshot_display", "-f", remotePath]
        if let screen = await cachedDetails(for: deviceID).map(\.resolution),
           let target = quality.captureSize(for: screen) {
            captureArguments += ["-w", String(Int(target.width)), "-h", String(Int(target.height))]
        }

        let capture = await execute(deviceID, captureArguments, timeout: 4)
        guard capture.succeeded else {
            throw HDCError.commandFailed(Self.friendlyError(capture))
        }

        let receive = await execute(deviceID, ["file", "recv", remotePath, localURL.path], timeout: 4)
        guard receive.succeeded else {
            throw HDCError.commandFailed(Self.friendlyError(receive))
        }
        guard let data = try? Data(contentsOf: localURL), data.count > 128 else {
            throw HDCError.invalidFrame
        }
        return CapturedFrame(
            data: data,
            latency: Date().timeIntervalSince(startedAt),
            sourceResolution: Self.parseResolution(capture.combinedOutput)
        )
    }

    func installAndLaunch(packageURL: URL, deviceID: String) async throws -> AppPackageInfo {
        guard packageURL.pathExtension.lowercased() == "hap" else { throw HDCError.invalidPackage }
        let manifest = await CommandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-p", packageURL.path, "module.json"], timeout: 15
        )
        guard manifest.succeeded, let data = manifest.stdout.data(using: .utf8),
              let info = Self.parsePackageInfo(data) else { throw HDCError.invalidPackage }

        let install = await execute(deviceID, ["install", "-r", packageURL.path], timeout: 180)
        guard install.succeeded, !Self.outputIndicatesFailure(install.combinedOutput) else {
            throw HDCError.commandFailed(Self.friendlyError(install))
        }

        var arguments = ["shell", "aa", "start", "-b", info.identifier]
        if let module = info.moduleName { arguments += ["-m", module] }
        if let ability = info.entryPoint { arguments += ["-a", ability] }
        let launch = await execute(deviceID, arguments, timeout: 15)
        guard launch.succeeded, !Self.outputIndicatesFailure(launch.combinedOutput) else {
            throw HDCError.commandFailed("HAP 已安装，但启动失败：\(Self.friendlyError(launch))")
        }
        return info
    }

    static func parsePackageInfo(_ data: Data) -> AppPackageInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = root["app"] as? [String: Any],
              let identifier = app["bundleName"] as? String, !identifier.isEmpty,
              let module = root["module"] as? [String: Any] else { return nil }
        let moduleName = (module["name"] as? String)?.nilIfEmpty
        let mainElement = (module["mainElement"] as? String)?.nilIfEmpty
        let abilities = module["abilities"] as? [[String: Any]] ?? []
        let firstAbility = abilities.compactMap { ($0["name"] as? String)?.nilIfEmpty }.first
        return AppPackageInfo(
            identifier: identifier, moduleName: moduleName, entryPoint: mainElement ?? firstAbility
        )
    }

    func send(_ command: RemoteCommand, to deviceID: String, resolution: CGSize) async -> Bool {
        switch command {
        case .touchDown, .touchMove, .touchUp:
            if let touchClient, touchDeviceID == deviceID {
                do {
                    try await touchClient.send(action: command, resolution: resolution)
                    return true
                } catch {
                    await touchClient.disconnect(deviceID: deviceID)
                    self.touchClient = nil
                    touchDeviceID = nil
                }
            }
            return false
        case .scroll:
            return false
        default:
            break
        }
        let arguments: [String]
        switch command {
        case .tap(let point):
            let pixel = Self.pixel(point, resolution: resolution)
            arguments = ["shell", "uitest", "uiInput", "click", "\(pixel.x)", "\(pixel.y)"]
        case .swipe(let from, let to, let duration):
            let start = Self.pixel(from, resolution: resolution)
            let end = Self.pixel(to, resolution: resolution)
            let velocity = max(200, min(40_000, Int(1_000_000 / max(duration * 1_000, 50))))
            arguments = ["shell", "uitest", "uiInput", "swipe",
                         "\(start.x)", "\(start.y)", "\(end.x)", "\(end.y)", "\(velocity)"]
        case .touchDown, .touchMove, .touchUp, .scroll:
            return false
        case .namedKey(let name):
            arguments = ["shell", "uitest", "uiInput", "keyEvent", name]
        case .keyCode(let code):
            arguments = ["shell", "uitest", "uiInput", "keyEvent", "\(code)"]
        case .keyCombination(let first, let second):
            arguments = ["shell", "uitest", "uiInput", "keyEvent", "\(first)", "\(second)"]
        case .text(let text):
            arguments = ["shell", "uitest", "uiInput", "text", text]
        }
        return await execute(deviceID, arguments, timeout: 3).succeeded
    }

    func startSystemRecording(deviceID: String, filename: String) async throws {
        let result = await execute(deviceID, [
            "shell", "aa", "start",
            "-b", "com.huawei.hmos.screenrecorder",
            "-a", "com.huawei.hmos.screenrecorder.ServiceExtAbility",
            "--ps", "CustomizedFileName", filename
        ], timeout: 5)
        guard result.succeeded, result.combinedOutput.localizedCaseInsensitiveContains("success") else {
            throw HDCError.commandFailed(Self.friendlyError(result))
        }
    }

    func stopSystemRecordingAndReceive(
        deviceID: String,
        filename: String,
        destination: URL
    ) async throws -> String {
        let stop = await execute(deviceID, [
            "shell", "aa", "start",
            "-b", "com.huawei.hmos.screenrecorder",
            "-a", "com.huawei.hmos.screenrecorder.ServiceExtAbility"
        ], timeout: 5)
        guard stop.succeeded else { throw HDCError.commandFailed(Self.friendlyError(stop)) }

        let mediaURI = try await waitForMediaURI(deviceID: deviceID, filename: filename)
        let remotePath = "/data/local/tmp/phone_mirror_record_\(sessionID).mp4"
        defer {
            Task { await self.removeRemoteFile(deviceID: deviceID, path: remotePath) }
        }

        let export = await execute(deviceID, ["shell", "mediatool", "recv", mediaURI, remotePath], timeout: 15)
        guard export.succeeded else { throw HDCError.commandFailed(Self.friendlyError(export)) }

        let receive = await execute(deviceID, ["file", "recv", remotePath, destination.path], timeout: 30)
        guard receive.succeeded else { throw HDCError.commandFailed(Self.friendlyError(receive)) }

        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 1_024, Self.isMP4File(destination) else { throw HDCError.invalidRecording }
        return mediaURI
    }

    func deleteMediaAsset(deviceID: String, mediaURI: String) async {
        _ = await execute(deviceID, ["shell", "mediatool", "delete", mediaURI], timeout: 5)
    }

    func removeCaptureArtifact(deviceID: String) async {
        _ = await execute(deviceID, ["shell", "rm", "-f", "/data/local/tmp/phone_mirror_\(sessionID).jpeg"], timeout: 2)
        _ = await execute(deviceID, ["shell", "rm", "-f", "/data/local/tmp/phone_mirror_\(sessionID).png"], timeout: 2)
    }

    func prepareRealtimeTouch(deviceID: String) async -> Bool {
        if touchClient != nil, touchDeviceID == deviceID { return true }
        if let touchClient, let touchDeviceID { await touchClient.disconnect(deviceID: touchDeviceID) }
        touchClient = nil
        touchDeviceID = nil
        guard let executable else { return false }
        let client = HarmonyTouchClient(hdc: executable)
        do {
            try await client.connect(deviceID: deviceID)
            touchClient = client
            touchDeviceID = deviceID
            return true
        } catch {
            await client.disconnect(deviceID: deviceID)
            return false
        }
    }

    func stopRealtimeTouch(deviceID: String?) async {
        if let touchClient { await touchClient.disconnect(deviceID: deviceID ?? touchDeviceID) }
        touchClient = nil
        touchDeviceID = nil
    }

    func startHarmonyStream(
        deviceID: String,
        onH264: @escaping @Sendable (Data, UInt64, Bool) -> Void,
        onExit: @escaping @Sendable () -> Void
    ) async throws {
        guard let executable else { throw HDCError.commandFailed("未找到 HDC") }
        if let videoClient {
            await videoClient.disconnect(deviceID: videoDeviceID, notify: false)
        }
        let client = HarmonyVideoClient(hdc: executable)
        videoClient = client
        videoDeviceID = deviceID
        do {
            try await client.connect(deviceID: deviceID, onH264: onH264, onExit: onExit)
        } catch {
            await client.disconnect(deviceID: deviceID, notify: false)
            if videoClient === client {
                videoClient = nil
                videoDeviceID = nil
            }
            throw error
        }
    }

    func stopHarmonyStream(deviceID: String?) async {
        if let videoClient {
            await videoClient.disconnect(deviceID: deviceID ?? videoDeviceID, notify: false)
        }
        videoClient = nil
        videoDeviceID = nil
    }

    private var detailCache: [String: DeviceDetails] = [:]

    private func cachedDetails(for deviceID: String) async -> DeviceDetails? {
        if let cached = detailCache[deviceID] { return cached }
        let value = await details(for: deviceID)
        detailCache[deviceID] = value
        return value
    }

    private func execute(_ deviceID: String, _ arguments: [String], timeout: TimeInterval) async -> CommandResult {
        guard let executable else {
            return CommandResult(status: -1, stdout: "", stderr: "未找到 hdc", timedOut: false)
        }
        return await CommandRunner.run(
            executable: executable,
            arguments: ["-t", deviceID] + arguments,
            timeout: timeout
        )
    }

    static func findExecutable(environment: [String: String]) -> URL? {
        var candidates = [
            "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc",
            "/Applications/DevEco Studio.app/Contents/sdk/default/openharmony/toolchains/hdc",
            "/opt/homebrew/bin/hdc",
            "/usr/local/bin/hdc"
        ]
        if let hdcHome = environment["HDC_HOME"] {
            candidates.insert(URL(fileURLWithPath: hdcHome).appendingPathComponent("hdc").path, at: 0)
        }
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("hdc").path
            })
        }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    static func parseResolution(_ output: String) -> CGSize? {
        let patterns = [
            #"activeModes<id, W, H, RS>:\s*\d+,\s*(\d+),\s*(\d+)"#,
            #"Bounds<L,T,W,H>:\s*\d+,\s*\d+,\s*(\d+),\s*(\d+)"#,
            #"process: display \d+[^\n]*width:\s*(\d+),\s*height:\s*(\d+)"#,
            #"Width:\s*(\d+)[\s\S]{0,80}?Height:\s*(\d+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                  let widthRange = Range(match.range(at: 1), in: output),
                  let heightRange = Range(match.range(at: 2), in: output),
                  let width = Double(output[widthRange]),
                  let height = Double(output[heightRange]),
                  width > 0, height > 0 else { continue }
            return CGSize(width: width, height: height)
        }
        return nil
    }

    static func parseMediaURI(_ output: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"[\"]?(file://media/[^\"\r\n]+)[\"]?"#),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return String(output[range])
    }

    private func waitForMediaURI(deviceID: String, filename: String) async throws -> String {
        for _ in 0..<20 {
            let query = await execute(deviceID, ["shell", "mediatool", "query", filename, "-u"], timeout: 4)
            if query.succeeded, let uri = Self.parseMediaURI(query.combinedOutput) { return uri }
            try? await Task.sleep(for: .milliseconds(350))
        }
        throw HDCError.recordingNotFound
    }

    private func removeRemoteFile(deviceID: String, path: String) async {
        _ = await execute(deviceID, ["shell", "rm", "-f", path], timeout: 3)
    }

    static func isMP4File(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count >= 8 else { return false }
        return String(data: header[4..<8], encoding: .ascii) == "ftyp"
    }

    private static func pixel(_ point: CGPoint, resolution: CGSize) -> (x: Int, y: Int) {
        (
            Int((point.x.clamped01 * resolution.width).rounded()),
            Int((point.y.clamped01 * resolution.height).rounded())
        )
    }

    private static func friendlyError(_ result: CommandResult) -> String {
        let output = result.combinedOutput
        if result.timedOut { return "HDC 响应超时" }
        if output.localizedCaseInsensitiveContains("device not found") ||
            output.localizedCaseInsensitiveContains("offline") {
            return "设备已断开，请检查 USB 连接"
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "HDC 命令执行失败"
    }

    private static func outputIndicatesFailure(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("error") || lower.contains("failed") || lower.contains("failure")
    }
}
enum HDCError: LocalizedError {
    case commandFailed(String)
    case invalidFrame
    case invalidRecording
    case recordingNotFound
    case invalidPackage

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): return message
        case .invalidFrame: return "手机返回了无效画面"
        case .invalidRecording: return "手机返回了无效的 MP4 录屏文件"
        case .recordingNotFound: return "系统录屏已停止，但没有在手机媒体库中找到视频"
        case .invalidPackage: return "无法读取 HAP 包信息，请确认文件完整"
        }
    }
}
