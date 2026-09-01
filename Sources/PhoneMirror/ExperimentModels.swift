import Foundation

enum ExperimentValueType: String, CaseIterable, Identifiable, Sendable {
    case json
    case string
    case boolean
    case integer
    case double

    var id: String { rawValue }

    var title: String {
        switch self {
        case .json: return "JSON"
        case .string: return "String"
        case .boolean: return "Boolean"
        case .integer: return "Integer"
        case .double: return "Double"
        }
    }

    static func inferred(from value: String) -> ExperimentValueType {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return .json }
        if trimmed == "true" || trimmed == "false" { return .boolean }
        if Int64(trimmed) != nil { return .integer }
        if Double(trimmed) != nil { return .double }
        return .string
    }

    func validatedText(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || self == .string else { throw ExperimentToolError.invalidValue("实验值不能为空") }
        switch self {
        case .string:
            return input
        case .boolean:
            guard trimmed == "true" || trimmed == "false" else {
                throw ExperimentToolError.invalidValue("Boolean 只能填写 true 或 false")
            }
            return trimmed
        case .integer:
            guard Int64(trimmed) != nil else {
                throw ExperimentToolError.invalidValue("请输入有效的 64 位整数")
            }
            return trimmed
        case .double:
            guard let number = Double(trimmed), number.isFinite else {
                throw ExperimentToolError.invalidValue("请输入有效的有限小数")
            }
            return trimmed
        case .json:
            guard let data = trimmed.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  value is [String: Any] || value is [Any] else {
                throw ExperimentToolError.invalidValue("JSON 类型请输入对象或数组")
            }
            return trimmed
        }
    }

    func jsonObject(from input: String) throws -> Any {
        let value = try validatedText(input)
        switch self {
        case .string:
            return value
        case .boolean:
            return value == "true"
        case .integer:
            return NSNumber(value: Int64(value)!)
        case .double:
            return NSNumber(value: Double(value)!)
        case .json:
            return try JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed])
        }
    }
}

struct ExperimentEntry: Identifiable, Equatable, Sendable {
    let key: String
    let value: String
    let serverValue: String?
    let overridden: Bool
    let vid: Int64?

    var id: String { key }
}

struct ExperimentCatalog: Equatable, Sendable {
    let entries: [ExperimentEntry]
    let summary: String
    let canAdd: Bool
    let canRemove: Bool
    let hasBackup: Bool
}

enum ExperimentToolError: LocalizedError {
    case invalidPackage
    case invalidKey(String)
    case invalidValue(String)
    case unsupported(String)
    case command(String)
    case corruptStorage(String)
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .invalidPackage: return "应用包名格式不正确"
        case .invalidKey(let message), .invalidValue(let message), .unsupported(let message),
             .command(let message), .corruptStorage(let message), .protocolError(let message):
            return message
        }
    }
}

enum ExperimentInput {
    static func normalizedPackage(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 255,
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_"
              }), value.first != ".", value.last != ".", !value.contains("..") else { return nil }
        return value
    }

    static func normalizedKey(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ExperimentToolError.invalidKey("实验 Key 不能为空") }
        guard value.utf8.count <= 1_024,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ExperimentToolError.invalidKey("实验 Key 包含无效字符或过长")
        }
        return value
    }

    static func displayText(for object: Any) -> String {
        if let string = object as? String { return string }
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: data, encoding: .utf8) else { return String(describing: object) }
        return result
    }
}
