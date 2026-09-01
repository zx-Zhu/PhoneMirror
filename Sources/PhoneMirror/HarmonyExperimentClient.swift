import Foundation
import Network

actor HarmonyExperimentClient {
    private let hdc: URL
    private let deviceID: String
    private let packageID: String
    private var requestSequence = 0

    init(hdc: URL, deviceID: String, packageID: String) {
        self.hdc = hdc
        self.deviceID = deviceID
        self.packageID = packageID
    }

    func load() async throws -> ExperimentCatalog {
        let session = try await connect()
        do {
            let entries = try await fetchEntries(session)
            await session.close()
            return ExperimentCatalog(
                entries: entries, summary: "common_abtest · \(entries.count) 个实验",
                canAdd: false, canRemove: false,
                hasBackup: ExperimentBackupStore.hasHarmonyBackup(deviceID: deviceID, packageID: packageID)
            )
        } catch {
            await session.close()
            throw error
        }
    }

    func set(key inputKey: String, value: String, type: ExperimentValueType, restart: Bool) async throws -> String {
        let key = try ExperimentInput.normalizedKey(inputKey)
        let valueObject = try type.jsonObject(from: value)
        let session = try await connect()
        do {
            let items = try await fetchRawItems(session)
            guard let item = items.first(where: { $0.key == key }), let raw = item.rawValue,
                  let data = raw.data(using: .utf8),
                  var wrapper = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ExperimentToolError.unsupported("鸿蒙仅允许修改 common_abtest 中已有的实验，不能新增 Key")
            }
            guard Self.validVID(wrapper["vid"]) != nil else {
                throw ExperimentToolError.corruptStorage("实验 \(key) 缺少有效 vid，已拒绝修改")
            }
            wrapper["val"] = valueObject
            let encoded = try Self.compactJSON(wrapper)
            try ExperimentBackupStore.saveHarmony(
                value: raw, key: key, deviceID: deviceID, packageID: packageID
            )
            do {
                try await writeRawValue(encoded, key: key, session: session)
                let reread = try await fetchRawItems(session).first(where: { $0.key == key })?.rawValue
                guard reread == encoded else {
                    throw ExperimentToolError.corruptStorage("实验写后校验失败")
                }
            } catch let writeError {
                do {
                    try await writeRawValue(raw, key: key, session: session)
                    let rolledBack = try await fetchRawItems(session).first(where: { $0.key == key })?.rawValue
                    guard rolledBack == raw else {
                        throw ExperimentToolError.corruptStorage("回滚后校验不一致")
                    }
                } catch let rollbackError {
                    throw ExperimentToolError.corruptStorage(
                        "实验写入失败且无法恢复原值：\(rollbackError.localizedDescription)"
                    )
                }
                throw ExperimentToolError.command("实验写入失败，已恢复原值：\(writeError.localizedDescription)")
            }
            await session.close()
        } catch {
            await session.close()
            throw error
        }
        if restart { try await restartApp() }
        return restart
            ? "已写入「\(key)」并重启 App；服务端实验刷新后可能再次覆盖"
            : "已写入「\(key)」；已读取实验需下次冷启动才会刷新"
    }

    func restore(restart: Bool) async throws -> String {
        let backup = try ExperimentBackupStore.loadHarmony(deviceID: deviceID, packageID: packageID)
        guard !backup.isEmpty else { throw ExperimentToolError.unsupported("没有可恢复的 HarmonyOS 实验快照") }
        let session = try await connect()
        do {
            let currentItems = try await fetchRawItems(session)
            let current = Dictionary(uniqueKeysWithValues: currentItems.compactMap { item in
                item.rawValue.map { (item.key, $0) }
            })
            guard backup.keys.allSatisfy({ current[$0] != nil }) else {
                throw ExperimentToolError.unsupported("快照中的部分实验已不在 common_abtest，已拒绝新增 Key")
            }
            for (key, value) in backup {
                guard let data = value.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["val"] != nil, Self.validVID(object["vid"]) != nil else {
                    throw ExperimentToolError.corruptStorage("实验 \(key) 的本地快照无效，已拒绝恢复")
                }
            }
            do {
                for key in backup.keys.sorted() {
                    guard let value = backup[key] else { continue }
                    try await writeRawValue(value, key: key, session: session)
                }
                let restored = Dictionary(uniqueKeysWithValues: try await fetchRawItems(session).compactMap { item in
                    item.rawValue.map { (item.key, $0) }
                })
                guard backup.allSatisfy({ restored[$0.key] == $0.value }) else {
                    throw ExperimentToolError.corruptStorage("HarmonyOS 实验快照恢复后校验失败")
                }
            } catch let restoreError {
                do {
                    for key in backup.keys.sorted() {
                        guard let value = current[key] else { continue }
                        try await writeRawValue(value, key: key, session: session)
                    }
                } catch let rollbackError {
                    throw ExperimentToolError.corruptStorage(
                        "快照恢复失败，且无法回滚本次操作：\(rollbackError.localizedDescription)"
                    )
                }
                throw ExperimentToolError.command("快照恢复失败，已回滚本次操作：\(restoreError.localizedDescription)")
            }
            await session.close()
        } catch {
            await session.close()
            throw error
        }
        if restart { try await restartApp() }
        return restart ? "已恢复 \(backup.count) 个实验快照并重启 App" : "已恢复 \(backup.count) 个实验快照"
    }

    private struct RawItem {
        let key: String
        let rawValue: String?
        let object: [String: Any]
    }

    private func fetchEntries(_ session: HarmonyHDPSession) async throws -> [ExperimentEntry] {
        try await fetchRawItems(session).map { item in
            let value = item.object["val"].map(ExperimentInput.displayText) ?? ""
            return ExperimentEntry(
                key: item.key, value: value, serverValue: nil, overridden: true,
                vid: Self.validVID(item.object["vid"])
            )
        }.sorted { $0.key < $1.key }
    }

    private func fetchRawItems(_ session: HarmonyHDPSession) async throws -> [RawItem] {
        let result = try await call(session, method: "KVStorage.getAllKV", params: [:])
        guard let response = result as? [String: Any], let values = response["result"] as? [[String: Any]] else {
            throw ExperimentToolError.protocolError("HDP 返回的 KVStorage 列表格式不正确")
        }
        var unique: [String: RawItem] = [:]
        for value in values where value["repo"] as? String == "common_abtest"
            && value["lib"] as? String == "keva" {
            guard let key = value["key"] as? String, let raw = value["value"] as? String,
                  let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["val"] != nil else { continue }
            unique[key] = RawItem(key: key, rawValue: raw, object: object)
        }
        return Array(unique.values)
    }

    private func connect() async throws -> HarmonyHDPSession {
        let session = HarmonyHDPSession()
        let localPort = UInt16.random(in: 38_000...58_000)
        let forward = await run(["fport", "tcp:\(localPort)", "tcp:7799"], timeout: 6)
        guard forward.succeeded else {
            await session.close()
            throw ExperimentToolError.command("连接 DevTool 协商端口失败，请先启动鸿蒙调试包：\(Self.message(forward))")
        }
        await session.addCleanup { [hdc, deviceID] in
            _ = await CommandRunner.run(
                executable: hdc, arguments: ["-t", deviceID, "fport", "rm", "tcp:\(localPort)", "tcp:7799"], timeout: 4
            )
        }
        do {
            try await session.connect(port: localPort)
            try await session.negotiateLocalTransport()
            try await session.waitForHandshake(timeout: 8)
            let appInfo = try await call(session, method: "AppInfo.getAppInfo", params: [:])
            let actualPackage = ((appInfo as? [String: Any])?["data"] as? [String: Any])?["packageName"] as? String
            guard actualPackage == packageID else {
                throw ExperimentToolError.unsupported(
                    "DevTool 当前连接的是 \(actualPackage ?? "未知应用")，不是 \(packageID)。请关闭占用 7799 端口的其他调试 App"
                )
            }
            return session
        } catch {
            await session.close()
            throw error
        }
    }

    private func call(_ session: HarmonyHDPSession, method: String, params: [String: Any]) async throws -> Any {
        requestSequence += 1
        let id = "phonemirror:\(requestSequence)"
        try await session.send(object: ["id": id, "method": method, "params": params])
        return try await session.waitForResponse(id: id, timeout: method == "KVStorage.getAllKV" ? 20 : 8)
    }

    private func writeRawValue(_ value: String, key: String, session: HarmonyHDPSession) async throws {
        _ = try await call(
            session, method: "KVStorage.setValue",
            params: ["key": key, "value": value, "repo": "common_abtest", "lib": "keva"]
        )
    }

    private func restartApp() async throws {
        let target = await launchTarget()
        let stop = await run(["shell", "aa", "force-stop", packageID], timeout: 6)
        guard stop.succeeded else { throw ExperimentToolError.command(Self.message(stop)) }
        try? await Task.sleep(for: .milliseconds(350))
        guard let target else {
            throw ExperimentToolError.command(
                "实验已写入并停止 App，但无法从 bm dump 解析启动入口，请手动启动 \(packageID)"
            )
        }
        let start = await run([
            "shell", "aa", "start", "-b", packageID,
            "-m", target.module, "-a", target.ability
        ], timeout: 12)
        guard start.succeeded, !start.combinedOutput.localizedCaseInsensitiveContains("error") else {
            throw ExperimentToolError.command("实验已写入，但 App 重启失败：\(Self.message(start))")
        }
    }

    private func launchTarget() async -> (module: String, ability: String)? {
        let dump = await run(["shell", "bm", "dump", "-n", packageID], timeout: 8)
        guard dump.succeeded else { return nil }
        return Self.parseLaunchTarget(dump.stdout.nilIfEmpty ?? dump.combinedOutput)
    }

    private func run(_ arguments: [String], timeout: TimeInterval) async -> CommandResult {
        await CommandRunner.run(executable: hdc, arguments: ["-t", deviceID] + arguments, timeout: timeout)
    }

    static func parseLaunchTarget(_ output: String) -> (module: String, ability: String)? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start <= end,
              let data = String(output[start...end]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modules = root["hapModuleInfos"] as? [[String: Any]], !modules.isEmpty else {
            return nil
        }
        let entryModule = root["entryModuleName"] as? String
        let orderedModules = modules.filter { ($0["moduleName"] as? String) == entryModule }
            + modules.filter { ($0["moduleName"] as? String) != entryModule }
        for module in orderedModules {
            guard let moduleName = module["moduleName"] as? String, !moduleName.isEmpty,
                  let abilities = module["abilityInfos"] as? [[String: Any]] else { continue }
            let ability = abilities.first(where: Self.isLauncherAbility)
                ?? abilities.first(where: { ($0["name"] as? String) == "MainAbility" })
                ?? abilities.first
            if let name = ability?["name"] as? String, !name.isEmpty {
                return (moduleName, name)
            }
        }
        return nil
    }

    private static func isLauncherAbility(_ ability: [String: Any]) -> Bool {
        if ability["isLauncherAbility"] as? Bool == true { return true }
        let skills = ability["skills"] as? [[String: Any]] ?? []
        return skills.contains { skill in
            (skill["actions"] as? [String] ?? []).contains("action.system.home")
        }
    }

    private static func compactJSON(_ object: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ExperimentToolError.invalidValue("实验值无法编码为 JSON")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private static func validVID(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.int64Value > 0 { return number.int64Value }
        if let string = value as? String, let number = Int64(string), number > 0 { return number }
        return nil
    }

    private static func message(_ result: CommandResult) -> String {
        result.timedOut ? "HDC 响应超时"
            : result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "HDC 命令失败"
    }
}

actor HarmonyHDPSession {
    private let queue = DispatchQueue(label: "com.zhuzhanxuan.phonemirror.hdp-tcp")
    private var connection: NWConnection?
    private var parser = HarmonyHDPJSONStreamParser()
    private var messages: [[String: Any]] = []
    private var handshakeComplete = false
    private var terminalError: Error?
    private var cleanups: [@Sendable () async -> Void] = []

    func connect(port: UInt16) async throws {
        guard let endpoint = NWEndpoint.Port(rawValue: port) else {
            throw ExperimentToolError.protocolError("无效的 HDP 本地端口")
        }
        let connection = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            Task { await self?.setError(error) }
        }
        connection.start(queue: queue)
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            switch connection.state {
            case .ready:
                receive(connection)
                return
            case .failed(let error):
                throw ExperimentToolError.protocolError("无法连接 DevTool 7799：\(error.localizedDescription)")
            case .cancelled:
                throw ExperimentToolError.protocolError("DevTool 7799 连接已取消")
            default:
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        throw ExperimentToolError.protocolError("DevTool 7799 连接超时，请先启动并保持鸿蒙调试包运行")
    }

    func negotiateLocalTransport() async throws {
        try await sendRaw(object: ["method": "pong", "data": ["hdpUrl": "local"]])
    }

    func addCleanup(_ cleanup: @escaping @Sendable () async -> Void) { cleanups.append(cleanup) }

    func waitForHandshake(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if handshakeComplete { return }
            if let terminalError { throw terminalError }
            try? await Task.sleep(for: .milliseconds(35))
        }
        throw ExperimentToolError.protocolError("App 未响应 HDP；请确认是 debug 包、DevTool 已初始化，且 7799 未被其他 App 占用")
    }

    func send(object: [String: Any]) async throws {
        guard handshakeComplete else {
            throw ExperimentToolError.protocolError("HDP 本地通道尚未就绪")
        }
        for message in try Self.requestMessages(object) {
            try await sendRaw(object: message)
        }
    }

    func waitForResponse(id: String, timeout: TimeInterval) async throws -> Any {
        let deadline = Date().addingTimeInterval(timeout)
        var parts: [Int: String] = [:]
        var expectedParts: Int?
        while Date() < deadline {
            if let message = takeMessage(id: id) {
                if let success = message["success"] as? Bool, !success {
                    let error = message["error"] as? [String: Any]
                    throw ExperimentToolError.protocolError(
                        "HDP 调用失败：\(error?["msg"] as? String ?? "未知错误")"
                    )
                }
                if let index = (message["index"] as? NSNumber)?.intValue,
                   let total = (message["total"] as? NSNumber)?.intValue,
                   let part = message["result"] as? String {
                    parts[index] = part
                    expectedParts = total
                    if parts.count == total {
                        let joined = (0..<total).compactMap { parts[$0] }.joined()
                        guard let data = joined.data(using: .utf8) else {
                            throw ExperimentToolError.protocolError("HDP 分片不是 UTF-8")
                        }
                        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                    }
                } else {
                    return message["result"] ?? [:]
                }
            }
            if let terminalError { throw terminalError }
            try? await Task.sleep(for: .milliseconds(25))
        }
        if let count = expectedParts {
            throw ExperimentToolError.protocolError("HDP 响应不完整（\(parts.count)/\(count)）")
        }
        throw ExperimentToolError.protocolError("HDP 调用响应超时")
    }

    func close() async {
        connection?.cancel()
        connection = nil
        let pending = cleanups
        cleanups = []
        for cleanup in pending { await cleanup() }
    }

    private func sendRaw(object: [String: Any]) async throws {
        guard let connection else {
            throw ExperimentToolError.protocolError("HDP 本地通道尚未连接")
        }
        let data = try Self.asciiJSONData(object)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1_024) { [weak self] data, _, complete, error in
            guard let self else { return }
            Task { await self.consume(data: data, complete: complete, error: error, connection: connection) }
        }
    }

    private func consume(data: Data?, complete: Bool, error: NWError?, connection: NWConnection) {
        if let data, !data.isEmpty {
            do {
                for message in try parser.append(data) {
                    if message["from"] as? String == "phone" { handshakeComplete = true }
                    else { messages.append(message) }
                }
            } catch {
                setError(error)
            }
        }
        if let error { setError(error) }
        if complete { setError(ExperimentToolError.protocolError("HDP 本地通道已断开")) }
        else if terminalError == nil { receive(connection) }
    }

    private func takeMessage(id: String) -> [String: Any]? {
        guard let index = messages.firstIndex(where: { $0["id"] as? String == id }) else { return nil }
        return messages.remove(at: index)
    }

    private func setError(_ error: Error) { if terminalError == nil { terminalError = error } }

    static func asciiJSONData(_ object: Any) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ExperimentToolError.protocolError("HDP 请求无法编码为 UTF-8")
        }
        var ascii = ""
        for scalar in json.unicodeScalars {
            let value = scalar.value
            if (0x20...0x7E).contains(value) {
                ascii.unicodeScalars.append(scalar)
            } else if value <= 0xFFFF {
                ascii += String(format: "\\u%04x", value)
            } else {
                let adjusted = value - 0x10000
                ascii += String(format: "\\u%04x\\u%04x", 0xD800 + adjusted / 0x400, 0xDC00 + adjusted % 0x400)
            }
        }
        return Data(ascii.utf8)
    }

    static func requestMessages(_ object: [String: Any]) throws -> [[String: Any]] {
        guard let id = object["id"] as? String, let method = object["method"] as? String,
              let params = object["params"] else { return [object] }
        let encoded = try asciiJSONData(params)
        let chunkSize = 60 * 1_024
        guard encoded.count > chunkSize else { return [object] }
        let total = (encoded.count + chunkSize - 1) / chunkSize
        return (0..<total).map { index in
            let start = index * chunkSize
            let end = min(start + chunkSize, encoded.count)
            return [
                "id": id, "method": method,
                "params": String(decoding: encoded[start..<end], as: UTF8.self),
                "hasMore": index < total - 1, "index": index, "total": total
            ]
        }
    }
}

struct HarmonyHDPJSONStreamParser {
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [[String: Any]] {
        buffer.append(data)
        guard buffer.count <= 32 * 1_024 * 1_024 else {
            throw ExperimentToolError.protocolError("HDP 消息超过 32MB，已停止解析")
        }
        var messages: [[String: Any]] = []
        while true {
            while let first = buffer.first, first == 0x20 || first == 0x09 || first == 0x0A || first == 0x0D {
                buffer.removeFirst()
            }
            guard !buffer.isEmpty else { break }
            guard buffer.first == UInt8(ascii: "{") else {
                throw ExperimentToolError.protocolError("HDP 返回了无法识别的数据")
            }
            guard let end = Self.objectEnd(in: buffer) else { break }
            let raw = Data(buffer[...end])
            buffer.removeSubrange(...end)
            guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                throw ExperimentToolError.protocolError("HDP 返回的消息不是 JSON 对象")
            }
            messages.append(object)
        }
        return messages
    }

    private static func objectEnd(in data: Data) -> Data.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        for index in data.indices {
            let byte = data[index]
            if escaped {
                escaped = false
            } else if inString {
                if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "{") {
                depth += 1
            } else if byte == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }
}
