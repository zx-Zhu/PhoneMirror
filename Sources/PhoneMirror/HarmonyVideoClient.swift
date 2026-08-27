import Foundation
import Network

/// Runs DevEco Testing's temporary UiTest screen-casting extension over HDC.
/// Nothing is installed on the phone: the shared object lives in /data/local/tmp.
actor HarmonyVideoClient {
    private static let remoteLibrary = "/data/local/tmp/libscreen_casting.z.so"
    private static let remoteSocket = "localabstract:scrcpy_grpc_socket"
    private static let remotePort = 8_710

    private let hdc: URL
    private let queue = DispatchQueue(label: "com.zhuzhanxuan.phonemirror.harmony-video", qos: .userInteractive)
    private var connection: NWConnection?
    private var bridgeProcess: Process?
    private var bridgeOutput: Pipe?
    private var grpcPort: UInt16?
    private var bridgePort: UInt16?
    private var connectedDeviceID: String?

    init(hdc: URL) { self.hdc = hdc }

    func connect(
        deviceID: String,
        onH264: @escaping @Sendable (Data, UInt64, Bool) -> Void,
        onExit: @escaping @Sendable () -> Void
    ) async throws {
        await disconnect(deviceID: connectedDeviceID, notify: false)
        guard let library = Self.resourceURL(named: "libscreen_casting.z.so"),
              let bridge = Self.resourceURL(named: "harmony_cast_bridge.py"),
              let pythonPath = Self.pythonExecutablePath(),
              let pythonModules = Self.resourceURL(named: "harmony_python", directory: true) else {
            throw HarmonyVideoError.resourcesMissing
        }

        connectedDeviceID = deviceID
        try await deployAndStart(deviceID: deviceID, library: library)
        let ports = try await allocatePorts(deviceID: deviceID)
        grpcPort = ports.grpc
        bridgePort = ports.bridge
        try await createForward(deviceID: deviceID, localPort: ports.grpc)
        try startBridge(
            pythonPath: pythonPath, bridgeScript: bridge, modules: pythonModules,
            grpcPort: ports.grpc, bridgePort: ports.bridge, onExit: onExit
        )
        try await waitForBridge(port: ports.bridge)

        guard let endpointPort = NWEndpoint.Port(rawValue: ports.bridge) else {
            throw HarmonyVideoError.invalidPort
        }
        let socket = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        let exitOnce = CallbackOnce(onExit)
        socket.stateUpdateHandler = { state in
            if case .failed = state { exitOnce.call() }
            if case .cancelled = state { exitOnce.call() }
        }
        connection = socket
        socket.start(queue: queue)
        do {
            try await waitUntilReady(socket, timeout: 6)
        } catch {
            await disconnect(deviceID: deviceID, notify: false)
            throw HarmonyVideoError.connectionFailed(error.localizedDescription)
        }
        receive(socket, demuxer: HarmonyCastingPacketDemuxer(onVideo: onH264), onExit: exitOnce)
    }

    func disconnect(deviceID: String?, notify: Bool = true) async {
        let socket = connection
        if !notify { socket?.stateUpdateHandler = nil }
        socket?.cancel()
        connection = nil

        if let process = bridgeProcess {
            if !notify { process.terminationHandler = nil }
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(0.8)
                while process.isRunning, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(40))
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        bridgeOutput?.fileHandleForReading.readabilityHandler = nil
        bridgeProcess = nil
        bridgeOutput = nil

        if let grpcPort, let deviceID = deviceID ?? connectedDeviceID {
            _ = await run(deviceID, ["fport", "rm", "tcp:\(grpcPort)", Self.remoteSocket], timeout: 3)
            await stopCastingProcess(deviceID: deviceID)
        }
        grpcPort = nil
        bridgePort = nil
        connectedDeviceID = nil
    }

    private func deployAndStart(deviceID: String, library: URL) async throws {
        await stopCastingProcess(deviceID: deviceID)
        _ = await run(deviceID, ["shell", "rm", "-f", Self.remoteLibrary], timeout: 3)
        let send = await run(deviceID, ["file", "send", library.path, Self.remoteLibrary], timeout: 10)
        guard send.succeeded else { throw HarmonyVideoError.commandFailed(Self.friendlyError(send)) }
        _ = await run(deviceID, ["shell", "chmod", "755", Self.remoteLibrary], timeout: 3)
        _ = await run(deviceID, ["shell", "param", "set", "persist.ace.testmode.enabled", "1"], timeout: 3)
        let start = await run(deviceID, [
            "shell", "uitest", "start-daemon", "singleness",
            "--extension-name", "libscreen_casting.z.so",
            "-scale", "1", "-frameRate", "60", "-bitRate", "31457280",
            "-p", String(Self.remotePort), "-screenId", "0", "-encodeType", "0",
            "-iFrameInterval", "2000", "-repeatInterval", "33"
        ], timeout: 8)
        guard start.succeeded || start.timedOut else {
            throw HarmonyVideoError.commandFailed(Self.friendlyError(start))
        }
        try? await Task.sleep(for: .milliseconds(800))
        let processes = await run(deviceID, ["shell", "ps", "-ef"], timeout: 4)
        guard processes.stdout.contains("libscreen_casting.z.so") else {
            throw HarmonyVideoError.extensionFailed
        }
    }

    private func stopCastingProcess(deviceID: String) async {
        let processes = await run(deviceID, ["shell", "ps", "-ef"], timeout: 4)
        let pids = processes.stdout.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.contains("libscreen_casting.z.so") else { return nil }
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count > 1, columns[1].allSatisfy(\.isNumber) else { return nil }
            return String(columns[1])
        }
        if !pids.isEmpty {
            _ = await run(deviceID, ["shell", "kill", "-9"] + pids, timeout: 4)
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private func allocatePorts(deviceID: String) async throws -> (grpc: UInt16, bridge: UInt16) {
        let existing = await run(deviceID, ["fport", "ls"], timeout: 4)
        for line in existing.stdout.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 3, fields[0] == deviceID, fields[2] == Self.remoteSocket else { continue }
            _ = await run(deviceID, ["fport", "rm", fields[1], Self.remoteSocket], timeout: 3)
        }
        for _ in 0..<20 {
            let grpc = UInt16.random(in: 39_100...46_000)
            let bridge = UInt16.random(in: 46_100...53_000)
            guard grpc != bridge, Self.localPortIsAvailable(grpc), Self.localPortIsAvailable(bridge) else { continue }
            return (grpc, bridge)
        }
        throw HarmonyVideoError.invalidPort
    }

    private func createForward(deviceID: String, localPort: UInt16) async throws {
        let result = await run(
            deviceID, ["fport", "tcp:\(localPort)", Self.remoteSocket], timeout: 5
        )
        guard result.succeeded else { throw HarmonyVideoError.commandFailed(Self.friendlyError(result)) }
    }

    private func startBridge(
        pythonPath: String, bridgeScript: URL, modules: URL,
        grpcPort: UInt16, bridgePort: UInt16, onExit: @escaping @Sendable () -> Void
    ) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [
            bridgeScript.path, "--grpc-port", String(grpcPort),
            "--bridge-port", String(bridgePort),
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = modules.path
        environment["NO_PROXY"] = "127.0.0.1,localhost"
        for key in ["http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "all_proxy"] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        let exitOnce = CallbackOnce(onExit)
        process.terminationHandler = { _ in
            output.fileHandleForReading.readabilityHandler = nil
            exitOnce.call()
        }
        try process.run()
        bridgeProcess = process
        bridgeOutput = output
    }

    private nonisolated func receive(
        _ socket: NWConnection, demuxer: HarmonyCastingPacketDemuxer, onExit: CallbackOnce
    ) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, complete, error in
            if let data, !data.isEmpty { demuxer.consume(data) }
            if complete || error != nil {
                onExit.call()
            } else {
                self?.receive(socket, demuxer: demuxer, onExit: onExit)
            }
        }
    }

    private func waitUntilReady(_ socket: NWConnection, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch socket.state {
            case .ready: return
            case .failed(let error): throw error
            case .cancelled: throw HarmonyVideoError.connectionFailed("连接已取消")
            default: try? await Task.sleep(for: .milliseconds(40))
            }
        }
        throw HarmonyVideoError.connectionFailed("连接 HarmonyOS H.264 bridge 超时")
    }

    private func waitForBridge(port: UInt16) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if bridgeProcess?.isRunning == false {
                throw HarmonyVideoError.connectionFailed("HarmonyOS H.264 bridge 启动失败")
            }
            if Self.localPortIsListening(port) { return }
            try? await Task.sleep(for: .milliseconds(80))
        }
        throw HarmonyVideoError.connectionFailed("HarmonyOS H.264 bridge 启动超时")
    }

    private func run(_ deviceID: String, _ arguments: [String], timeout: TimeInterval) async -> CommandResult {
        await CommandRunner.run(executable: hdc, arguments: ["-t", deviceID] + arguments, timeout: timeout)
    }

    private static func resourceURL(named name: String, directory: Bool = false) -> URL? {
        let bundle = Bundle.main.resourceURL?.appendingPathComponent(name, isDirectory: directory)
        let projectBase = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let project = directory
            ? projectBase.appendingPathComponent("third_party/\(name)", isDirectory: true)
            : projectBase.appendingPathComponent(name.hasSuffix(".py") ? "scripts/\(name)" : "third_party/\(name)")
        return [bundle, project].compactMap { $0 }.first {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                && (!directory || isDirectory.boolValue)
        }
    }

    private static func pythonExecutablePath() -> String? {
        let candidates = [
            "/Applications/DevEco_Testing_for_App.app/Contents/Python/bin/python3",
            "/opt/homebrew/bin/python3", "/usr/local/bin/python3"
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    private static func localPortIsAvailable(_ port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func localPortIsListening(_ port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func friendlyError(_ result: CommandResult) -> String {
        if result.timedOut { return "HDC 响应超时" }
        return result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "HDC 命令执行失败"
    }
}

enum HarmonyVideoError: LocalizedError {
    case resourcesMissing
    case extensionFailed
    case invalidPort
    case commandFailed(String)
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .resourcesMissing: return "缺少 HarmonyOS H.264 运行资源"
        case .extensionFailed: return "HarmonyOS H.264 扩展启动失败"
        case .invalidPort: return "无法建立 HarmonyOS 视频端口"
        case .commandFailed(let message), .connectionFailed(let message): return message
        }
    }
}
