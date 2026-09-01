import Foundation

enum ExperimentBackupStore {
    private struct AndroidMetadata: Codable {
        let createdAt: Date
        let mainFile: String
        let crcFile: String
    }

    private struct HarmonyBackup: Codable {
        let createdAt: Date
        let values: [String: String]
    }

    static func saveAndroid(main: Data, crc: Data, deviceID: String, packageID: String) throws {
        let directory = try backupDirectory(platform: "android", deviceID: deviceID, packageID: packageID)
        let mainURL = directory.appendingPathComponent("override.mmkv")
        let crcURL = directory.appendingPathComponent("override.mmkv.crc")
        try main.write(to: mainURL, options: .atomic)
        try crc.write(to: crcURL, options: .atomic)
        let metadata = AndroidMetadata(createdAt: Date(), mainFile: mainURL.lastPathComponent, crcFile: crcURL.lastPathComponent)
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
    }

    static func loadAndroid(deviceID: String, packageID: String) throws -> (main: Data, crc: Data)? {
        let directory = try backupDirectory(
            platform: "android", deviceID: deviceID, packageID: packageID, create: false
        )
        let mainURL = directory.appendingPathComponent("override.mmkv")
        let crcURL = directory.appendingPathComponent("override.mmkv.crc")
        guard FileManager.default.fileExists(atPath: mainURL.path),
              FileManager.default.fileExists(atPath: crcURL.path) else { return nil }
        return (try Data(contentsOf: mainURL), try Data(contentsOf: crcURL))
    }

    static func hasAndroidBackup(deviceID: String, packageID: String) -> Bool {
        (try? loadAndroid(deviceID: deviceID, packageID: packageID)) != nil
    }

    static func saveHarmony(value: String, key: String, deviceID: String, packageID: String) throws {
        let directory = try backupDirectory(platform: "harmony", deviceID: deviceID, packageID: packageID)
        let url = directory.appendingPathComponent("values.json")
        let existing = try loadHarmonyFile(url)
        var values = existing?.values ?? [:]
        values[key] = value
        let backup = HarmonyBackup(createdAt: Date(), values: values)
        try JSONEncoder().encode(backup).write(to: url, options: .atomic)
    }

    static func loadHarmony(deviceID: String, packageID: String) throws -> [String: String] {
        let directory = try backupDirectory(
            platform: "harmony", deviceID: deviceID, packageID: packageID, create: false
        )
        return try loadHarmonyFile(directory.appendingPathComponent("values.json"))?.values ?? [:]
    }

    static func hasHarmonyBackup(deviceID: String, packageID: String) -> Bool {
        ((try? loadHarmony(deviceID: deviceID, packageID: packageID)) ?? [:]).isEmpty == false
    }

    private static func loadHarmonyFile(_ url: URL) throws -> HarmonyBackup? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(HarmonyBackup.self, from: Data(contentsOf: url))
    }

    private static func backupDirectory(
        platform: String, deviceID: String, packageID: String, create: Bool = true
    ) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: create
        ).appendingPathComponent("PhoneMirror/ExperimentBackups", isDirectory: true)
        let directory = root
            .appendingPathComponent(component(platform), isDirectory: true)
            .appendingPathComponent(component(deviceID), isDirectory: true)
            .appendingPathComponent(component(packageID), isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private static func component(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}
