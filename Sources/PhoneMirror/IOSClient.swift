import Foundation

/// Read-only iOS device discovery and screenshot fallback. Live mirroring is
/// handled by IOSCaptureClient through macOS's QuickTime/CoreMediaIO path.
actor IOSClient {
    static let shared = IOSClient()

    private let ideviceID: URL?
    private let ideviceInfo: URL?
    private let screenshotTool: URL?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        ideviceID = Self.find("idevice_id", environment: environment)
        ideviceInfo = Self.find("ideviceinfo", environment: environment)
        screenshotTool = Self.find("idevicescreenshot", environment: environment)
    }

    var executablePath: String? { ideviceID?.path }

    func listDevices() async -> [MirrorDevice] {
        guard let ideviceID else { return [] }
        let result = await CommandRunner.run(executable: ideviceID, arguments: ["-l"], timeout: 4)
        guard result.succeeded else { return [] }
        var devices = MirrorDevice.parseIOSList(result.stdout)
        for index in devices.indices {
            let name = await info(devices[index].serial, key: "DeviceName").nilIfEmpty
            let device = devices[index]
            devices[index] = MirrorDevice(
                platform: device.platform, serial: device.serial, transport: device.transport,
                state: device.state, endpoint: device.endpoint, advertisedModel: name
            )
        }
        return devices
    }

    func details(for device: MirrorDevice) async -> DeviceDetails {
        async let name = info(device.serial, key: "DeviceName")
        async let product = info(device.serial, key: "ProductType")
        async let version = info(device.serial, key: "ProductVersion")
        let values = await (name, product, version)
        let displayName = values.0.nilIfEmpty ?? Self.friendlyModel(values.1.nilIfEmpty ?? "")
        return DeviceDetails(
            model: displayName.nilIfEmpty ?? "iPhone / iPad",
            version: values.2.nilIfEmpty.map { "iOS \($0)" } ?? "iOS",
            resolution: CGSize(width: 1179, height: 2556)
        )
    }

    func capture(deviceID: String) async throws -> Data {
        guard let screenshotTool else { throw IOSClientError.toolMissing("idevicescreenshot") }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneMirror-iOS-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await CommandRunner.run(
            executable: screenshotTool, arguments: ["-u", deviceID, url.path], timeout: 12
        )
        guard result.succeeded else { throw IOSClientError.commandFailed(Self.friendlyError(result)) }
        let candidates = [url, url.appendingPathExtension("png"), url.deletingPathExtension().appendingPathExtension("tiff")]
        guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: source), data.count > 128 else {
            throw IOSClientError.invalidScreenshot
        }
        return data
    }

    private func info(_ deviceID: String, key: String) async -> String {
        guard let ideviceInfo else { return "" }
        let result = await CommandRunner.run(
            executable: ideviceInfo, arguments: ["-u", deviceID, "-k", key], timeout: 5
        )
        return result.succeeded ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    private static func find(_ name: String, environment: [String: String]) -> URL? {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"] +
            (environment["PATH"]?.split(separator: ":").map { "\($0)/\(name)" } ?? [])
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    private static func friendlyModel(_ productType: String) -> String {
        if productType.hasPrefix("iPad") { return "iPad" }
        if productType.hasPrefix("iPhone") { return "iPhone" }
        return productType
    }

    private static func friendlyError(_ result: CommandResult) -> String {
        if result.timedOut { return "iOS 设备响应超时" }
        return result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "iOS 截图服务不可用"
    }
}

enum IOSClientError: LocalizedError {
    case toolMissing(String), commandFailed(String), invalidScreenshot

    var errorDescription: String? {
        switch self {
        case .toolMissing(let tool): return "未找到 \(tool)"
        case .commandFailed(let message): return message
        case .invalidScreenshot: return "iOS 设备没有返回有效截图，请保持解锁并信任此 Mac"
        }
    }
}
