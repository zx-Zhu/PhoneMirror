import Foundation

/// Minimal codec for the unencrypted MMKV SharedPreferences file used by the
/// Android debug override layer. Existing bytes are retained verbatim and a
/// last-wins string entry is appended, matching MMKV's native write strategy.
struct MMKVDocument {
    private let originalMain: Data
    private let originalCRC: Data
    private let region: Data
    private let entries: [String: Data]
    private let sequence: UInt32
    private let version: UInt32

    init(main: Data, crc: Data) throws {
        guard main.count >= 8 else { throw ExperimentToolError.corruptStorage("MMKV 数据文件过小") }
        guard crc.count >= 32 else { throw ExperimentToolError.corruptStorage("MMKV CRC 文件过小") }
        let actualSize = Int(main.littleEndianUInt32(at: 0))
        guard actualSize >= 4, actualSize <= main.count - 4 else {
            throw ExperimentToolError.corruptStorage("MMKV actualSize 越界")
        }
        let region = Data(main[4..<(4 + actualSize)])
        let iv = crc[12..<28]
        guard iv.allSatisfy({ $0 == 0 }) else {
            throw ExperimentToolError.unsupported("目标 MMKV 已加密，为避免损坏已拒绝修改")
        }
        let expectedCRC = crc.littleEndianUInt32(at: 0)
        guard CRC32.checksum(region) == expectedCRC else {
            throw ExperimentToolError.corruptStorage("MMKV CRC 校验失败，为避免损坏已拒绝修改")
        }

        var parsed: [String: Data] = [:]
        var offset = 4 // MMKV data region begins with a four-byte sentinel.
        while offset < region.count {
            let keyLength = try Self.readVarint(region, offset: &offset)
            guard keyLength <= UInt64(region.count - offset) else {
                throw ExperimentToolError.corruptStorage("MMKV Key 长度越界")
            }
            let keyData = Data(region[offset..<(offset + Int(keyLength))])
            offset += Int(keyLength)
            guard let key = String(data: keyData, encoding: .utf8) else {
                throw ExperimentToolError.corruptStorage("MMKV Key 不是 UTF-8")
            }
            let valueLength = try Self.readVarint(region, offset: &offset)
            guard valueLength <= UInt64(region.count - offset) else {
                throw ExperimentToolError.corruptStorage("MMKV Value 长度越界")
            }
            parsed[key] = Data(region[offset..<(offset + Int(valueLength))])
            offset += Int(valueLength)
        }

        self.originalMain = main
        self.originalCRC = crc
        self.region = region
        self.entries = parsed
        sequence = crc.littleEndianUInt32(at: 8)
        version = crc.littleEndianUInt32(at: 4)
    }

    func string(for key: String) throws -> String? {
        guard let raw = entries[key], !raw.isEmpty else { return nil }
        var offset = 0
        let length = try Self.readVarint(raw, offset: &offset)
        guard length == raw.count - offset,
              let value = String(data: raw[offset..<raw.count], encoding: .utf8) else {
            throw ExperimentToolError.corruptStorage("MMKV 中的 \(key) 不是有效字符串")
        }
        return value
    }

    func appendingString(_ value: String, for key: String) throws -> (main: Data, crc: Data) {
        let keyData = Data(key.utf8)
        let valueData = Data(value.utf8)
        var encodedValue = Self.varint(UInt64(valueData.count))
        encodedValue.append(valueData)

        var appended = Self.varint(UInt64(keyData.count))
        appended.append(keyData)
        appended.append(Self.varint(UInt64(encodedValue.count)))
        appended.append(encodedValue)

        var newRegion = region
        newRegion.append(appended)
        guard newRegion.count <= Int(UInt32.max) else {
            throw ExperimentToolError.unsupported("MMKV 文件超过支持大小")
        }

        var newMain = Data()
        newMain.appendLittleEndian(UInt32(newRegion.count))
        newMain.append(newRegion)
        let originalPageSize = max(4_096, originalMain.count)
        let pageSize = ((max(newMain.count, originalPageSize) + 4_095) / 4_096) * 4_096
        newMain.append(Data(repeating: 0, count: pageSize - newMain.count))

        var newCRC = originalCRC
        newCRC.replaceLittleEndianUInt32(at: 0, with: CRC32.checksum(newRegion))
        newCRC.replaceLittleEndianUInt32(at: 4, with: version)
        newCRC.replaceLittleEndianUInt32(at: 8, with: sequence &+ 1)
        newCRC.replaceLittleEndianUInt32(at: 28, with: UInt32(newRegion.count))

        let verification = try MMKVDocument(main: newMain, crc: newCRC)
        guard try verification.string(for: key) == value else {
            throw ExperimentToolError.corruptStorage("MMKV 写入前往返校验失败")
        }
        return (newMain, newCRC)
    }

    var originalPair: (main: Data, crc: Data) { (originalMain, originalCRC) }

    private static func readVarint(_ data: Data, offset: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count, shift <= 63 {
            let byte = data[offset]
            offset += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        throw ExperimentToolError.corruptStorage("MMKV varint 无效")
    }

    private static func varint(_ value: UInt64) -> Data {
        var remaining = value
        var result = Data()
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            result.append(byte)
        } while remaining != 0
        return result
    }
}

enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            var current = (crc ^ UInt32(byte)) & 0xff
            for _ in 0..<8 {
                current = current & 1 == 1 ? (current >> 1) ^ 0xedb8_8320 : current >> 1
            }
            crc = (crc >> 8) ^ current
        }
        return crc ^ 0xffff_ffff
    }
}

private extension Data {
    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }

    mutating func replaceLittleEndianUInt32(at offset: Int, with value: UInt32) {
        self[offset] = UInt8(value & 0xff)
        self[offset + 1] = UInt8((value >> 8) & 0xff)
        self[offset + 2] = UInt8((value >> 16) & 0xff)
        self[offset + 3] = UInt8((value >> 24) & 0xff)
    }
}
