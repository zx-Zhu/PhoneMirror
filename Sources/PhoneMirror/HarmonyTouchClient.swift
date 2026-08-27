import Foundation
import Network

actor HarmonyTouchClient {
    private static let remoteAgent = "/data/local/tmp/agent.so"
    private static let legacyRemotePort = "tcp:8012"
    private static let unixRemoteSocket = "localabstract:uitest_socket"
    private static let header = Data("_uitestkit_rpc_message_head_".utf8)
    private static let tail = Data("_uitestkit_rpc_message_tail_".utf8)

    private let hdc: URL
    private let queue = DispatchQueue(label: "com.zhuzhanxuan.phonemirror.harmony-touch", qos: .userInteractive)
    private var connection: NWConnection?
    private var localPort: UInt16?
    private var forwardedRemoteEndpoint: String?
    private var reader: HarmonyRPCReader?
    private var sequence: UInt32 = UInt32.random(in: 1...UInt32.max - 1)

    init(hdc: URL) { self.hdc = hdc }

    func connect(deviceID: String) async throws {
        await disconnect(deviceID: deviceID)
        guard let agent = Self.agentURL() else { throw HarmonyTouchError.agentMissing }

        let version = await run(
            deviceID,
            ["shell", "sh", "-c", "cat /data/local/tmp/agent.so 2>/dev/null | grep -a UITEST_AGENT_LIBRARY | head -1"],
            timeout: 3
        )
        let processList = await run(deviceID, ["shell", "ps", "-ef"], timeout: 3)
        let daemonRunning = processList.stdout.contains("uitest start-daemon singleness")
        let uiTestVersion = await run(deviceID, ["shell", "uitest", "--version"], timeout: 3)
        let remoteEndpoint = Self.usesUnixSocket(uiTestVersion.stdout)
            ? Self.unixRemoteSocket : Self.legacyRemotePort
        if !version.stdout.contains("#1.2.4") || !daemonRunning {
            let processIDs = processList.stdout.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                guard line.contains("uitest start-daemon singleness") else { return nil }
                let columns = line.split(whereSeparator: \.isWhitespace)
                guard columns.count > 1, columns[1].allSatisfy(\.isNumber) else { return nil }
                return String(columns[1])
            }
            if !processIDs.isEmpty {
                _ = await run(deviceID, ["shell", "kill", "-9"] + processIDs, timeout: 3)
            }
            _ = await run(deviceID, ["shell", "rm", "-f", Self.remoteAgent], timeout: 3)
            let send = await run(deviceID, ["file", "send", agent.path, Self.remoteAgent], timeout: 10)
            guard send.succeeded else { throw HarmonyTouchError.commandFailed(send.combinedOutput) }
            _ = await run(deviceID, ["shell", "chmod", "+x", Self.remoteAgent], timeout: 3)
            _ = await run(deviceID, ["shell", "param", "set", "persist.ace.testmode.enabled", "1"], timeout: 3)
            let daemon = await run(deviceID, ["shell", "uitest", "start-daemon", "singleness"], timeout: 5)
            guard daemon.succeeded || daemon.timedOut else { throw HarmonyTouchError.commandFailed(daemon.combinedOutput) }
            try? await Task.sleep(for: .milliseconds(500))
        }

        await removeStaleForwards(deviceID: deviceID)
        var selectedPort: UInt16?
        var lastForwardError = ""
        for _ in 0..<12 {
            let candidate = UInt16.random(in: 18_000...29_000)
            let forward = await run(deviceID, ["fport", "tcp:\(candidate)", remoteEndpoint], timeout: 5)
            if forward.succeeded {
                selectedPort = candidate
                break
            }
            lastForwardError = forward.combinedOutput
        }
        guard let port = selectedPort else { throw HarmonyTouchError.commandFailed(lastForwardError) }
        localPort = port
        forwardedRemoteEndpoint = remoteEndpoint

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw HarmonyTouchError.invalidPort }
        let socket = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        let reader = HarmonyRPCReader()
        self.reader = reader
        self.connection = socket
        socket.start(queue: queue)
        receive(socket, reader: reader)
        try await waitUntilReady(socket)
        _ = try await call(method: "CtrlCmd", api: "getDisplaySize", args: [:], timeout: 2)
    }

    func disconnect(deviceID: String?) async {
        connection?.cancel()
        connection = nil
        reader?.cancelAll()
        reader = nil
        if let localPort, let deviceID, let forwardedRemoteEndpoint {
            _ = await run(deviceID, ["fport", "rm", "tcp:\(localPort)", forwardedRemoteEndpoint], timeout: 3)
        }
        localPort = nil
        forwardedRemoteEndpoint = nil
    }

    func send(action: RemoteCommand, resolution: CGSize) async throws {
        let point: CGPoint
        let api: String
        switch action {
        case .touchDown(let value): api = "touchDown"; point = value
        case .touchMove(let value): api = "touchMove"; point = value
        case .touchUp(let value): api = "touchUp"; point = value
        default: throw HarmonyTouchError.unsupportedCommand
        }
        let pixel = Self.pixel(point, resolution: resolution)
        _ = try await call(method: "Gestures", api: api, args: ["x": pixel.x, "y": pixel.y], timeout: 1)
    }

    private func call(method: String, api: String, args: Any, timeout: TimeInterval) async throws -> Data {
        guard let connection, let reader else { throw HarmonyTouchError.notConnected }
        sequence &+= 1
        let requestID = sequence
        let object: [String: Any] = [
            "module": "com.ohos.devicetest.hypiumApiHelper",
            "method": method,
            "params": ["api": api, "args": args]
        ]
        let json = try JSONSerialization.data(withJSONObject: object)
        var packet = Data(capacity: Self.header.count + 8 + json.count + Self.tail.count)
        packet.append(Self.header)
        packet.appendBigEndian(requestID)
        packet.appendBigEndian(UInt32(json.count))
        packet.append(json)
        packet.append(Self.tail)

        return try await withCheckedThrowingContinuation { continuation in
            reader.register(id: requestID, timeout: timeout, continuation: continuation)
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error { reader.fail(id: requestID, error: error) }
            })
        }
    }

    private nonisolated func receive(_ socket: NWConnection, reader: HarmonyRPCReader) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            if let data, !data.isEmpty { reader.consume(data) }
            if complete || error != nil { reader.cancelAll() } else { self?.receive(socket, reader: reader) }
        }
    }

    private func waitUntilReady(_ socket: NWConnection) async throws {
        let started = Date()
        while Date().timeIntervalSince(started) < 3 {
            switch socket.state {
            case .ready: return
            case .failed(let error): throw error
            case .cancelled: throw HarmonyTouchError.notConnected
            default: try? await Task.sleep(for: .milliseconds(30))
            }
        }
        throw HarmonyTouchError.timeout
    }

    private func run(_ deviceID: String, _ arguments: [String], timeout: TimeInterval) async -> CommandResult {
        await CommandRunner.run(executable: hdc, arguments: ["-t", deviceID] + arguments, timeout: timeout)
    }

    private func removeStaleForwards(deviceID: String) async {
        let result = await run(deviceID, ["fport", "ls"], timeout: 4)
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            let columns = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard columns.count >= 3, columns[0] == deviceID,
                  columns[2] == Self.legacyRemotePort || columns[2] == Self.unixRemoteSocket else { continue }
            _ = await run(deviceID, ["fport", "rm", columns[1], columns[2]], timeout: 3)
        }
    }

    private static func usesUnixSocket(_ versionOutput: String) -> Bool {
        let components = versionOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".").compactMap { Int($0) }
        let padded = components + Array(repeating: 0, count: max(0, 4 - components.count))
        return Array(padded.prefix(4)).lexicographicallyPrecedes([6, 0, 2, 2]) == false
    }

    private static func pixel(_ point: CGPoint, resolution: CGSize) -> (x: Int, y: Int) {
        (Int((point.x.clamped01 * resolution.width).rounded()), Int((point.y.clamped01 * resolution.height).rounded()))
    }

    private static func agentURL() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("uitest_agent_v1.2.4.so"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("third_party/uitest_agent_v1.2.4.so")
        ].compactMap { $0 }
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

}

final class HarmonyRPCReader: @unchecked Sendable {
    private static let header = Data("_uitestkit_rpc_message_head_".utf8)
    private static let tail = Data("_uitestkit_rpc_message_tail_".utf8)
    private let lock = NSLock()
    private var buffer = Data()
    private var pending: [UInt32: CheckedContinuation<Data, Error>] = [:]

    func register(id: UInt32, timeout: TimeInterval, continuation: CheckedContinuation<Data, Error>) {
        lock.lock(); pending[id] = continuation; lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.fail(id: id, error: HarmonyTouchError.timeout)
        }
    }

    func fail(id: UInt32, error: Error) {
        lock.lock(); let continuation = pending.removeValue(forKey: id); lock.unlock()
        continuation?.resume(throwing: error)
    }

    func cancelAll() {
        lock.lock(); let continuations = Array(pending.values); pending.removeAll(); lock.unlock()
        continuations.forEach { $0.resume(throwing: HarmonyTouchError.notConnected) }
    }

    func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var completed: [(CheckedContinuation<Data, Error>, Result<Data, Error>)] = []
        while buffer.count >= Self.header.count + 8 {
            guard buffer.starts(with: Self.header) else { buffer.removeFirst(); continue }
            let idOffset = Self.header.count
            let id = buffer.readUInt32(at: idOffset)
            let length = Int(buffer.readUInt32(at: idOffset + 4))
            let total = Self.header.count + 8 + length + Self.tail.count
            guard length >= 0, length <= 4 * 1_024 * 1_024, buffer.count >= total else { break }
            let payloadStart = idOffset + 8
            let payload = Data(buffer[payloadStart..<(payloadStart + length)])
            let tail = Data(buffer[(payloadStart + length)..<total])
            buffer.removeSubrange(0..<total)
            guard tail == Self.tail, let continuation = pending.removeValue(forKey: id) else { continue }
            if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let exception = object["exception"] {
                completed.append((continuation, .failure(HarmonyTouchError.remote(String(describing: exception)))))
            } else {
                completed.append((continuation, .success(payload)))
            }
        }
        lock.unlock()
        completed.forEach { $0.0.resume(with: $0.1) }
    }

    var bufferedByteCount: Int {
        lock.lock(); defer { lock.unlock() }; return buffer.count
    }
}

enum HarmonyTouchError: LocalizedError {
    case agentMissing, invalidPort, notConnected, timeout, unsupportedCommand, commandFailed(String), remote(String)
    var errorDescription: String? {
        switch self {
        case .agentMissing: return "缺少 HarmonyOS 实时触控代理"
        case .invalidPort: return "无法建立 HarmonyOS 触控端口"
        case .notConnected: return "HarmonyOS 实时触控未连接"
        case .timeout: return "HarmonyOS 触控响应超时"
        case .unsupportedCommand: return "不支持的触控命令"
        case .commandFailed(let message), .remote(let message): return message
        }
    }
}
