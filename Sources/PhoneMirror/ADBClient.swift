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
    private var runtimeSettingsKeys: [String: Set<String>] = [:]
    private var runtimeSettingsValues: [String: [String: String]] = [:]
    private var runtimeSettingsSessions: [String: RuntimeSettingsSession] = [:]

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

    func loadExperiments(packageID: String, deviceID: String) async throws -> ExperimentCatalog {
        let package = try Self.validatedPackage(packageID)
        try await ensureRunAs(package: package, deviceID: deviceID)
        let overrides = try await readAndroidOverrideMap(package: package, deviceID: deviceID)
        let catalog = (try? await readAndroidCatalog(package: package, deviceID: deviceID)) ?? [:]
        let keys = Set(overrides.keys).union(catalog.keys).sorted()
        let entries = keys.map { key -> ExperimentEntry in
            let server = catalog[key].map(ExperimentInput.displayText)
            return ExperimentEntry(
                key: key, value: overrides[key] ?? server ?? "", serverValue: server,
                overridden: overrides[key] != nil, vid: nil
            )
        }
        return ExperimentCatalog(
            entries: entries,
            summary: "服务端实验 \(catalog.count) · 本地覆盖 \(overrides.count)",
            canAdd: true, canRemove: true,
            hasBackup: ExperimentBackupStore.hasAndroidBackup(deviceID: deviceID, packageID: package)
        )
    }

    func setExperiment(
        packageID: String, deviceID: String, key inputKey: String, value: String,
        type: ExperimentValueType, restart: Bool, temporary: Bool
    ) async throws -> String {
        let package = try Self.validatedPackage(packageID)
        let key = try ExperimentInput.normalizedKey(inputKey)
        let validated = try type.validatedText(value)
        try await ensureRunAs(package: package, deviceID: deviceID)
        try await forceStop(package: package, deviceID: deviceID)
        try? await Task.sleep(for: .milliseconds(350))

        let original = try await readAndroidPair(package: package, deviceID: deviceID)
        let document = try MMKVDocument(main: original.main, crc: original.crc)
        var map = try Self.decodeOverrideMap(try document.string(for: Self.abOverrideKey))
        let originalMap = map
        map[key] = validated
        let payload = try Self.encodeOverrideMap(map)
        let updated = try document.appendingString(payload, for: Self.abOverrideKey)
        try ExperimentBackupStore.saveAndroid(
            main: original.main, crc: original.crc, deviceID: deviceID, packageID: package
        )
        try await writeAndroidPair(
            updated, rollback: original, package: package, deviceID: deviceID
        )

        if temporary {
            do {
                try await launch(package: package, deviceID: deviceID)
                try await waitUntilRunning(package: package, deviceID: deviceID)
                // Restore only the override-map entry against the latest live
                // file, retaining unrelated debug properties written at launch.
                let live = try await readAndroidPair(package: package, deviceID: deviceID)
                let liveDocument = try MMKVDocument(main: live.main, crc: live.crc)
                let restoredPayload = try Self.encodeOverrideMap(originalMap)
                let restored = try liveDocument.appendingString(restoredPayload, for: Self.abOverrideKey)
                try await writeAndroidPair(restored, rollback: live, package: package, deviceID: deviceID)
            } catch {
                do {
                    try await forceStop(package: package, deviceID: deviceID)
                    try await writeAndroidPair(original, rollback: updated, package: package, deviceID: deviceID)
                } catch {
                    throw ExperimentToolError.command("临时实验启动失败，且磁盘快照回滚失败：\(error.localizedDescription)")
                }
                throw ExperimentToolError.command("临时实验启动失败，已恢复原始磁盘快照：\(error.localizedDescription)")
            }
            return "已覆盖「\(key)」，仅当前运行有效"
        }
        if restart { try await launch(package: package, deviceID: deviceID) }
        return restart ? "已覆盖「\(key)」并重启 App" : "已写入「\(key)」，App 当前保持停止"
    }

    func removeExperiment(
        packageID: String, deviceID: String, key inputKey: String, restart: Bool
    ) async throws -> String {
        let package = try Self.validatedPackage(packageID)
        let key = try ExperimentInput.normalizedKey(inputKey)
        try await ensureRunAs(package: package, deviceID: deviceID)
        try await forceStop(package: package, deviceID: deviceID)
        try? await Task.sleep(for: .milliseconds(350))
        let original = try await readAndroidPair(package: package, deviceID: deviceID)
        let document = try MMKVDocument(main: original.main, crc: original.crc)
        var map = try Self.decodeOverrideMap(try document.string(for: Self.abOverrideKey))
        map.removeValue(forKey: key)
        let payload = try Self.encodeOverrideMap(map)
        let updated = try document.appendingString(payload, for: Self.abOverrideKey)
        try ExperimentBackupStore.saveAndroid(
            main: original.main, crc: original.crc, deviceID: deviceID, packageID: package
        )
        try await writeAndroidPair(updated, rollback: original, package: package, deviceID: deviceID)
        if restart { try await launch(package: package, deviceID: deviceID) }
        return restart ? "已移除「\(key)」覆盖并重启 App" : "已移除「\(key)」覆盖，App 当前保持停止"
    }

    func restoreExperimentBackup(packageID: String, deviceID: String, restart: Bool) async throws -> String {
        let package = try Self.validatedPackage(packageID)
        try await ensureRunAs(package: package, deviceID: deviceID)
        guard let backup = try ExperimentBackupStore.loadAndroid(deviceID: deviceID, packageID: package) else {
            throw ExperimentToolError.unsupported("没有可恢复的 Android 实验快照")
        }
        _ = try MMKVDocument(main: backup.main, crc: backup.crc)
        try await forceStop(package: package, deviceID: deviceID)
        try? await Task.sleep(for: .milliseconds(350))
        let current = try await readAndroidPair(package: package, deviceID: deviceID)
        try await writeAndroidPair(backup, rollback: current, package: package, deviceID: deviceID)
        try ExperimentBackupStore.saveAndroid(
            main: current.main, crc: current.crc, deviceID: deviceID, packageID: package
        )
        if restart { try await launch(package: package, deviceID: deviceID) }
        return restart ? "已恢复上次快照并重启 App" : "已恢复上次快照，App 当前保持停止"
    }

    func loadSettings(packageID: String, deviceID: String) async throws -> ExperimentCatalog {
        let package = try Self.validatedPackage(packageID)
        try await ensureRunAs(package: package, deviceID: deviceID)
        let processID = try await runningProcessID(package: package, deviceID: deviceID)
        let cacheKey = Self.runtimeSettingsCacheKey(deviceID: deviceID, package: package)
        if runtimeSettingsSessions[cacheKey]?.processID != processID {
            runtimeSettingsSessions.removeValue(forKey: cacheKey)
            runtimeSettingsKeys.removeValue(forKey: cacheKey)
            runtimeSettingsValues.removeValue(forKey: cacheKey)
        } else if let session = runtimeSettingsSessions[cacheKey],
                  let supportedKeys = runtimeSettingsKeys[cacheKey],
                  let values = runtimeSettingsValues[cacheKey] {
            return Self.runtimeSettingsCatalog(
                values: values, supportedKeys: supportedKeys, overrides: session.overrides
            )
        }
        let values = try await readAndroidSettingsValues(package: package, deviceID: deviceID)
        let supportedKeys = try await filterRuntimeSettingsKeys(
            Set(values.keys), package: package, deviceID: deviceID
        )
        runtimeSettingsKeys[cacheKey] = supportedKeys
        runtimeSettingsValues[cacheKey] = values
        var sessionOverrides = runtimeSettingsSessions[cacheKey]?.overrides ?? [:]
        sessionOverrides = sessionOverrides.filter { supportedKeys.contains($0.key) }
        var originals = runtimeSettingsSessions[cacheKey]?.originals ?? [:]
        originals = originals.filter { supportedKeys.contains($0.key) }
        runtimeSettingsSessions[cacheKey] = RuntimeSettingsSession(
            processID: processID, overrides: sessionOverrides, originals: originals
        )
        return Self.runtimeSettingsCatalog(
            values: values, supportedKeys: supportedKeys, overrides: sessionOverrides
        )
    }

    func setSetting(
        packageID: String, deviceID: String, key inputKey: String, value: String,
        type: ExperimentValueType
    ) async throws -> String {
        let package = try Self.validatedPackage(packageID)
        let key = try ExperimentInput.normalizedKey(inputKey)
        let validated = try type.validatedText(value)
        try await ensureRunAs(package: package, deviceID: deviceID)
        let processID = try await runningProcessID(package: package, deviceID: deviceID)
        let cacheKey = Self.runtimeSettingsCacheKey(deviceID: deviceID, package: package)
        if runtimeSettingsSessions[cacheKey]?.processID != processID {
            runtimeSettingsSessions.removeValue(forKey: cacheKey)
            runtimeSettingsKeys.removeValue(forKey: cacheKey)
            runtimeSettingsValues.removeValue(forKey: cacheKey)
        }
        if runtimeSettingsKeys[cacheKey]?.contains(key) != true {
            _ = try await loadSettings(packageID: package, deviceID: deviceID)
        }
        guard runtimeSettingsKeys[cacheKey]?.contains(key) == true else {
            throw ExperimentToolError.unsupported("该配置不经过 SsConfigMgr，无法安全地仅在运行时覆盖")
        }
        var session = runtimeSettingsSessions[cacheKey] ?? RuntimeSettingsSession(
            processID: processID, overrides: [:], originals: [:]
        )
        let previous = try await setRuntimeSetting(
            key: key, value: validated, package: package, deviceID: deviceID
        )
        if session.originals[key] == nil {
            session.originals[key] = RuntimeSettingOriginal(value: previous)
        }
        session.overrides[key] = validated
        runtimeSettingsSessions[cacheKey] = session
        return "已更新运行时 Settings「\(key)」，退出 App 后自动失效"
    }

    func clearSetting(packageID: String, deviceID: String, key inputKey: String) async throws -> String {
        let package = try Self.validatedPackage(packageID)
        let key = try ExperimentInput.normalizedKey(inputKey)
        try await ensureRunAs(package: package, deviceID: deviceID)
        let processID = try await runningProcessID(package: package, deviceID: deviceID)
        let cacheKey = Self.runtimeSettingsCacheKey(deviceID: deviceID, package: package)
        guard var session = runtimeSettingsSessions[cacheKey], session.processID == processID,
              session.overrides[key] != nil else {
            throw ExperimentToolError.unsupported("该配置不是 PhoneMirror 本次运行添加的覆盖")
        }
        if let original = session.originals[key]?.value {
            _ = try await setRuntimeSetting(
                key: key, value: original, package: package, deviceID: deviceID
            )
        } else {
            try await clearRuntimeSetting(key: key, package: package, deviceID: deviceID)
        }
        session.overrides.removeValue(forKey: key)
        session.originals.removeValue(forKey: key)
        runtimeSettingsSessions[cacheKey] = session
        return "已清除运行时 Settings「\(key)」"
    }

    static func parsePackageInfo(_ output: String) -> AppPackageInfo? {
        guard let identifier = firstCapture(#"package:\s+name='([^']+)'"#, in: output) else { return nil }
        let activity = firstCapture(#"launchable-activity:\s+name='([^']+)'"#, in: output)
        return AppPackageInfo(identifier: identifier, moduleName: nil, entryPoint: activity)
    }

    private static let abOverrideFile = "files/mmkv/prefix_public_debug_properties"
    private static let abOverrideKey = "key_ab_info_local_override_result"
    private static let abCatalogFile = "files/mmkv/id_common_ab_result"
    private static let abCatalogKey = "key_common_ab_result_json"
    private static let settingsPreferencesFile = "shared_prefs/BDLocationCache.xml"

    private struct RuntimeBridgeResult: Decodable {
        let success: Bool
        let message: String
        let candidateCount: Int?
        let supportedCount: Int?
        let supportedBitmapBase64: String?
        let previousValueBase64: String?

        enum CodingKeys: String, CodingKey {
            case success, message
            case candidateCount = "candidate_count"
            case supportedCount = "supported_count"
            case supportedBitmapBase64 = "supported_bitmap_base64"
            case previousValueBase64 = "previous_value_base64"
        }
    }

    private struct RuntimeSettingsSession {
        let processID: String
        var overrides: [String: String]
        var originals: [String: RuntimeSettingOriginal]
    }

    private struct RuntimeSettingOriginal {
        let value: String?
    }

    private static func validatedPackage(_ input: String) throws -> String {
        guard let package = ExperimentInput.normalizedPackage(input) else { throw ExperimentToolError.invalidPackage }
        return package
    }

    private func ensureRunAs(package: String, deviceID: String) async throws {
        let result = await execute(deviceID, ["exec-out", "run-as", package, "id"], timeout: 5)
        guard result.succeeded, result.stdout.contains("uid=") else {
            throw ExperimentToolError.unsupported("run-as 失败，请确认包名正确且当前安装包为 debuggable")
        }
    }

    private func readAndroidOverrideMap(package: String, deviceID: String) async throws -> [String: String] {
        let pair = try await readAndroidPair(package: package, deviceID: deviceID)
        let document = try MMKVDocument(main: pair.main, crc: pair.crc)
        return try Self.decodeOverrideMap(try document.string(for: Self.abOverrideKey))
    }

    private func readAndroidCatalog(package: String, deviceID: String) async throws -> [String: Any] {
        let main = try await runAsRead(Self.abCatalogFile, package: package, deviceID: deviceID)
        let crc = try await runAsRead(Self.abCatalogFile + ".crc", package: package, deviceID: deviceID)
        let document = try MMKVDocument(main: main, crc: crc)
        guard let raw = try document.string(for: Self.abCatalogKey), let data = raw.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return root.mapValues { value in
            if let item = value as? [String: Any], let actual = item["val"] { return actual }
            return value
        }
    }

    private func readAndroidSettingsValues(
        package: String, deviceID: String
    ) async throws -> [String: String] {
        let xml = try await runAsRead(
            Self.settingsPreferencesFile, package: package, deviceID: deviceID
        )
        return try Self.decodeAndroidSettingsPreferences(xml)
    }

    static func decodeAndroidSettingsPreferences(_ xml: Data) throws -> [String: String] {
        guard let source = String(data: xml, encoding: .utf8),
              let match = source.range(
                of: #"<string\s+name=["']bd_location_settings["'][^>]*>([\s\S]*?)</string>"#,
                options: .regularExpression
              ) else {
            throw ExperimentToolError.corruptStorage("未找到 Android Settings 数据")
        }
        let element = String(source[match])
        guard let contentStart = element.firstIndex(of: ">"),
              let contentEnd = element.range(of: "</string>", options: .backwards)?.lowerBound else {
            throw ExperimentToolError.corruptStorage("Android Settings XML 格式无效")
        }
        let raw = String(element[element.index(after: contentStart)..<contentEnd])
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        guard let data = raw.data(using: .utf8),
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExperimentToolError.corruptStorage("未找到可解析的 Android Settings 数据")
        }
        var result: [String: String] = [:]
        for (key, value) in object {
            if let string = value as? String {
                result[key] = string
            } else if !(value is NSNull),
                      let encoded = try? JSONSerialization.data(
                        withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]
                      ),
                      let string = String(data: encoded, encoding: .utf8) {
                result[key] = string
            }
        }
        return result
    }

    private static func decodeOverrideMap(_ raw: String?) throws -> [String: String] {
        guard let raw, !raw.isEmpty else { return [:] }
        guard let data = raw.data(using: .utf8),
              let map = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw ExperimentToolError.corruptStorage("本地实验覆盖不是合法的 JSON 字符串映射")
        }
        return map
    }

    private static func encodeOverrideMap(_ map: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: map, options: [.sortedKeys])
        guard let result = String(data: data, encoding: .utf8) else {
            throw ExperimentToolError.invalidValue("实验覆盖无法编码为 UTF-8")
        }
        return result
    }

    private func readAndroidPair(package: String, deviceID: String) async throws -> (main: Data, crc: Data) {
        let main = try await runAsRead(Self.abOverrideFile, package: package, deviceID: deviceID)
        let crc = try await runAsRead(Self.abOverrideFile + ".crc", package: package, deviceID: deviceID)
        return (main, crc)
    }

    private func runAsRead(_ path: String, package: String, deviceID: String) async throws -> Data {
        let result = await executeData(
            ["-s", deviceID, "exec-out", "run-as", package, "cat", path], timeout: 8
        )
        guard result.status == 0, !result.data.isEmpty else {
            throw ExperimentToolError.command("读取 \(path) 失败：\(result.stderr.nilIfEmpty ?? "文件不存在，请先启动一次调试包")")
        }
        return result.data
    }

    private func writeAndroidPair(
        _ pair: (main: Data, crc: Data), rollback: (main: Data, crc: Data),
        package: String, deviceID: String
    ) async throws {
        do {
            try await pushRunAs(pair.crc, to: Self.abOverrideFile + ".crc", package: package, deviceID: deviceID)
            try await pushRunAs(pair.main, to: Self.abOverrideFile, package: package, deviceID: deviceID)
            let verified = try await readAndroidPair(package: package, deviceID: deviceID)
            guard verified.main == pair.main, verified.crc == pair.crc else {
                throw ExperimentToolError.command("写入后文件校验不一致")
            }
        } catch {
            try? await pushRunAs(rollback.crc, to: Self.abOverrideFile + ".crc", package: package, deviceID: deviceID)
            try? await pushRunAs(rollback.main, to: Self.abOverrideFile, package: package, deviceID: deviceID)
            throw ExperimentToolError.command("Android 实验写入失败，已尝试回滚：\(error.localizedDescription)")
        }
    }

    private func pushRunAs(_ data: Data, to path: String, package: String, deviceID: String) async throws {
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneMirror-\(UUID().uuidString).bin")
        let remote = "/data/local/tmp/phonemirror_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try data.write(to: local, options: .atomic)
        defer { try? FileManager.default.removeItem(at: local) }
        let push = await executeRaw(["-s", deviceID, "push", local.path, remote], timeout: 15)
        guard push.succeeded else { throw ExperimentToolError.command(Self.friendlyError(push)) }
        defer { Task { _ = await self.execute(deviceID, ["shell", "rm", "-f", remote], timeout: 3) } }
        let copy = await execute(
            deviceID, ["shell", "run-as", package, "cp", remote, path], timeout: 8
        )
        guard copy.succeeded else { throw ExperimentToolError.command(Self.friendlyError(copy)) }
    }

    private func forceStop(package: String, deviceID: String) async throws {
        let result = await execute(deviceID, ["shell", "am", "force-stop", package], timeout: 5)
        guard result.succeeded else { throw ExperimentToolError.command(Self.friendlyError(result)) }
    }

    private func runningProcessID(package: String, deviceID: String) async throws -> String {
        let result = await execute(deviceID, ["shell", "pidof", package], timeout: 3)
        guard result.succeeded, let processID = result.stdout.split(whereSeparator: \.isWhitespace).first else {
            throw ExperimentToolError.unsupported("请先启动 App；运行时 Settings 不会自动重启应用")
        }
        return String(processID)
    }

    private func setRuntimeSetting(
        key: String, value: String, package: String, deviceID: String
    ) async throws -> String? {
        let response = try await runRuntimeSettingsBridge(
            operation: "set", triggerKey: key,
            payload: Data(value.utf8).base64EncodedString(),
            package: package, deviceID: deviceID, timeout: 15
        )
        guard let encoded = response.previousValueBase64 else { return nil }
        guard let data = Data(base64Encoded: encoded),
              let previous = String(data: data, encoding: .utf8) else {
            throw ExperimentToolError.command("运行时 Settings 原值返回格式无效")
        }
        return previous
    }

    private func clearRuntimeSetting(
        key: String, package: String, deviceID: String
    ) async throws {
        _ = try await runRuntimeSettingsBridge(
            operation: "clear", triggerKey: key, payload: nil,
            package: package, deviceID: deviceID, timeout: 15
        )
    }

    private func filterRuntimeSettingsKeys(
        _ candidates: Set<String>, package: String, deviceID: String
    ) async throws -> Set<String> {
        guard !candidates.isEmpty else { return [] }
        let sortedCandidates = candidates.sorted()
        let payload = sortedCandidates.map {
            Data($0.utf8).base64EncodedString()
        }.joined(separator: "\n")
        let response = try await runRuntimeSettingsBridge(
            operation: "filter", triggerKey: sortedCandidates[0],
            payload: Data(payload.utf8).base64EncodedString(),
            package: package, deviceID: deviceID, timeout: 45
        )
        guard response.candidateCount == sortedCandidates.count,
              let supportedCount = response.supportedCount,
              let encoded = response.supportedBitmapBase64,
              let bitmap = Data(base64Encoded: encoded),
              bitmap.count == (sortedCandidates.count + 7) / 8 else {
            throw ExperimentToolError.command("运行时 Settings 白名单返回格式无效")
        }
        let keys = Set(sortedCandidates.enumerated().compactMap { index, key in
            bitmap[index / 8] & UInt8(1 << (index % 8)) == 0 ? nil : key
        })
        guard keys.count == supportedCount else {
            throw ExperimentToolError.command("运行时 Settings 白名单校验失败")
        }
        return keys
    }

    private func runRuntimeSettingsBridge(
        operation: String, triggerKey: String, payload: String?,
        package: String, deviceID: String, timeout: TimeInterval
    ) async throws -> RuntimeBridgeResult {
        guard let adb = executable else { throw ExperimentToolError.command("未找到 adb") }
        guard let java = Self.findJava() else {
            throw ExperimentToolError.unsupported("未找到 Java 17，无法连接 Android 运行时")
        }
        guard let bridge = Self.runtimeSettingsBridge() else {
            throw ExperimentToolError.unsupported("PhoneMirror 缺少运行时 Settings 组件，请重新构建应用")
        }
        let pid = try await runningProcessID(package: package, deviceID: deviceID)
        let forward = await executeRaw(
            ["-s", deviceID, "forward", "tcp:0", "jdwp:\(pid)"], timeout: 5
        )
        guard forward.succeeded,
              let port = Int(forward.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ExperimentToolError.unsupported(
                "无法连接 App 调试进程，请确认安装包为 debuggable 且未被其他调试器占用"
            )
        }
        var arguments = ["--add-modules", "jdk.jdi"]
        if bridge.pathExtension == "java" {
            arguments.append(contentsOf: [bridge.path, "127.0.0.1", "\(port)"])
        } else {
            arguments.append(contentsOf: ["-cp", bridge.path, "RuntimeSettingsBridge", "127.0.0.1", "\(port)"])
        }
        arguments.append(contentsOf: [adb.path, deviceID, package, operation, triggerKey])
        if let payload { arguments.append(payload) }
        let result = await CommandRunner.run(executable: java, arguments: arguments, timeout: timeout)
        _ = await executeRaw(
            ["-s", deviceID, "forward", "--remove", "tcp:\(port)"], timeout: 3
        )
        let response = result.stdout.split(whereSeparator: \.isNewline).last.flatMap { line in
            String(line).data(using: .utf8).flatMap {
                try? JSONDecoder().decode(RuntimeBridgeResult.self, from: $0)
            }
        }
        guard result.succeeded, let response, response.success else {
            throw ExperimentToolError.command(
                response?.message ?? result.stderr.nilIfEmpty ?? "运行时 Settings 调试失败"
            )
        }
        return response
    }

    private static func runtimeSettingsCacheKey(deviceID: String, package: String) -> String {
        deviceID + "\u{0}" + package
    }

    private static func runtimeSettingsCatalog(
        values: [String: String], supportedKeys: Set<String>, overrides: [String: String]
    ) -> ExperimentCatalog {
        let entries = supportedKeys.sorted().compactMap { key -> ExperimentEntry? in
            guard let value = overrides[key] ?? values[key] else { return nil }
            return ExperimentEntry(
                key: key, value: value, serverValue: nil,
                overridden: overrides[key] != nil, vid: nil
            )
        }
        return ExperimentCatalog(
            entries: entries,
            summary: "运行时 Settings \(entries.count) · 退出 App 后自动失效",
            canAdd: false, canRemove: true, hasBackup: false
        )
    }

    private static func findJava() -> URL? {
        let candidates = [
            "/usr/bin/java",
            "/opt/homebrew/opt/openjdk@17/bin/java",
            "/opt/homebrew/bin/java"
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private static func runtimeSettingsBridge() -> URL? {
        let bundle = Bundle.main.resourceURL?
            .appendingPathComponent("runtime-settings-bridge", isDirectory: true)
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tools/RuntimeSettingsBridge.java")
        return [bundle, source].compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private func launch(package: String, deviceID: String) async throws {
        let result = await execute(
            deviceID, ["shell", "monkey", "-p", package, "-c", "android.intent.category.LAUNCHER", "1"],
            timeout: 15
        )
        guard result.succeeded || result.timedOut else { throw ExperimentToolError.command(Self.friendlyError(result)) }
    }

    private func waitUntilRunning(package: String, deviceID: String) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let result = await execute(deviceID, ["shell", "pidof", package], timeout: 3)
            if result.succeeded, !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? await Task.sleep(for: .milliseconds(1_500))
                return
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        throw ExperimentToolError.command("等待 App 启动超时，临时覆盖未清理")
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
