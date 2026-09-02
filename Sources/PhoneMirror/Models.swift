import AppKit
import Foundation

enum DevicePlatform: String, Sendable, CaseIterable {
    case harmonyOS
    case android
    case ios

    var title: String {
        switch self {
        case .harmonyOS: return "HarmonyOS"
        case .android: return "Android"
        case .ios: return "iOS"
        }
    }

    var symbol: String {
        switch self {
        case .harmonyOS: return "h.circle.fill"
        case .android: return "a.circle.fill"
        case .ios: return "apple.logo"
        }
    }
}

struct MirrorDevice: Identifiable, Equatable, Sendable {
    enum State: String, Sendable {
        case connected = "Connected"
        case offline = "Offline"
        case unauthorized = "Unauthorized"
        case unknown = "Unknown"

        var isConnected: Bool { self == .connected }
    }

    let platform: DevicePlatform
    let serial: String
    let transport: String
    let state: State
    let endpoint: String
    let advertisedModel: String?

    var id: String { "\(platform.rawValue):\(serial)" }

    var shortID: String {
        serial.count > 15 ? String(serial.prefix(7)) + "…" + String(serial.suffix(5)) : serial
    }

    static func parseHDCList(_ output: String) -> [MirrorDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let columns = rawLine.split(whereSeparator: \.isWhitespace).map(String.init)
            guard columns.count >= 3 else { return nil }
            let state = State(rawValue: columns[2]) ?? .unknown
            return MirrorDevice(
                platform: .harmonyOS,
                serial: columns[0],
                transport: columns[1],
                state: state,
                endpoint: columns.count > 3 ? columns[3] : "",
                advertisedModel: nil
            )
        }
    }

    static func parseADBList(_ output: String) -> [MirrorDevice] {
        output.split(whereSeparator: \.isNewline).dropFirst().compactMap { rawLine in
            let columns = rawLine.split(whereSeparator: \.isWhitespace).map(String.init)
            guard columns.count >= 2 else { return nil }
            let state: State
            switch columns[1] {
            case "device": state = .connected
            case "offline": state = .offline
            case "unauthorized": state = .unauthorized
            default: state = .unknown
            }
            let model = columns.first(where: { $0.hasPrefix("model:") })
                .map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
            let isWireless = columns[0].contains(":")
            return MirrorDevice(
                platform: .android,
                serial: columns[0],
                transport: isWireless ? "Wi-Fi" : "USB",
                state: state,
                endpoint: "",
                advertisedModel: model
            )
        }
    }

    static func parseIOSList(_ output: String) -> [MirrorDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let serial = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !serial.isEmpty else { return nil }
            return MirrorDevice(
                platform: .ios, serial: serial, transport: "USB", state: .connected,
                endpoint: "", advertisedModel: nil
            )
        }
    }
}

struct DeviceDetails: Equatable, Sendable {
    var model = "HarmonyOS 设备"
    var version = ""
    var resolution = CGSize(width: 1260, height: 2720)
}

struct AppPackageInfo: Equatable, Sendable {
    let identifier: String
    let moduleName: String?
    let entryPoint: String?
}

enum SchemaLink {
    static func normalized(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let separator = value.firstIndex(of: ":"), separator != value.startIndex else { return nil }

        let scheme = value[..<separator]
        guard let first = scheme.unicodeScalars.first, CharacterSet.letters.contains(first),
              scheme.unicodeScalars.dropFirst().allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || CharacterSet(charactersIn: "+-.").contains($0)
              }) else { return nil }
        return value
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

enum SchemaLaunchResult: Equatable {
    case succeeded(String)
    case failed(String)
}

struct DeviceCommandRequest: Equatable, Sendable {
    let arguments: [String]

    static func parse(_ input: String, platform: DevicePlatform) throws -> DeviceCommandRequest {
        guard platform == .android || platform == .harmonyOS else {
            throw DeviceCommandError.unsupportedPlatform
        }
        guard input.utf8.count <= 16_384 else { throw DeviceCommandError.tooLong }
        var tokens = try tokenize(input)
        guard !tokens.isEmpty else { throw DeviceCommandError.empty }

        let first = URL(fileURLWithPath: tokens[0]).lastPathComponent.lowercased()
        let suppliedTool: DevicePlatform?
        switch first {
        case "adb", "adb.exe": suppliedTool = .android
        case "hdc", "hdc.exe": suppliedTool = .harmonyOS
        default: suppliedTool = nil
        }
        if let suppliedTool {
            guard suppliedTool == platform else {
                throw DeviceCommandError.wrongTool(expected: platform == .android ? "adb" : "hdc")
            }
            tokens.removeFirst()
        }
        let selector = platform == .android ? "-s" : "-t"
        if tokens.first == selector {
            guard tokens.count >= 3 else {
                throw DeviceCommandError.malformed("\(selector) 后缺少设备 ID 或子命令")
            }
            tokens.removeFirst(2)
        }
        guard !tokens.isEmpty else { throw DeviceCommandError.empty }
        guard tokens.count <= 256, tokens.allSatisfy({ $0.utf8.count <= 8_192 }) else {
            throw DeviceCommandError.tooLong
        }
        if tokens[0].hasPrefix("-") {
            throw DeviceCommandError.globalOption
        }
        return DeviceCommandRequest(arguments: tokens)
    }

    static func displayCommand(
        platform: DevicePlatform, deviceID: String, arguments: [String]
    ) -> String {
        let tool = platform == .android ? "adb" : "hdc"
        let selector = platform == .android ? "-s" : "-t"
        return ([tool, selector, quoted(deviceID)] + arguments.map(quoted)).joined(separator: " ")
    }

    private static func tokenize(_ input: String) throws -> [String] {
        guard !input.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw DeviceCommandError.malformed("指令不能包含空字符")
        }
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var tokenStarted = false

        for character in input {
            if escaping {
                current.append(character)
                tokenStarted = true
                escaping = false
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if activeQuote == "\"" && character == "\\" {
                    escaping = true
                } else {
                    current.append(character)
                }
                tokenStarted = true
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                tokenStarted = true
            } else if character == "\\" {
                escaping = true
                tokenStarted = true
            } else if character.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains) {
                if tokenStarted {
                    tokens.append(current)
                    current = ""
                    tokenStarted = false
                }
            } else {
                current.append(character)
                tokenStarted = true
            }
        }
        guard quote == nil else { throw DeviceCommandError.malformed("引号没有闭合") }
        guard !escaping else { throw DeviceCommandError.malformed("末尾转义符不完整") }
        if tokenStarted { tokens.append(current) }
        return tokens
    }

    private static func quoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_./:=+,-"))
        if value.unicodeScalars.allSatisfy(safe.contains) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

enum DeviceCommandError: LocalizedError, Equatable {
    case empty
    case unsupportedPlatform
    case wrongTool(expected: String)
    case globalOption
    case tooLong
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .empty: return "请输入 ADB/HDC 设备子命令"
        case .unsupportedPlatform: return "自定义设备指令当前仅支持 Android 和 HarmonyOS"
        case .wrongTool(let expected): return "当前设备应使用 \(expected) 指令"
        case .globalOption: return "不支持该全局参数；PhoneMirror 会自动绑定当前设备"
        case .tooLong: return "指令过长，请缩短后重试"
        case .malformed(let message): return "指令格式错误：\(message)"
        }
    }
}

struct DeviceCommandExecution: Equatable, Sendable {
    let commandLine: String
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let duration: TimeInterval

    var succeeded: Bool { status == 0 && !timedOut }

    var transcript: String {
        var sections = ["$ \(commandLine)"]
        if !stdout.isEmpty { sections.append(stdout.trimmingCharacters(in: .newlines)) }
        if !stderr.isEmpty { sections.append("[stderr]\n" + stderr.trimmingCharacters(in: .newlines)) }
        if stdout.isEmpty && stderr.isEmpty { sections.append("（无输出）") }
        let state = timedOut ? "timeout" : "exit \(status)"
        sections.append(String(format: "[%@ · %.2fs]", state, duration))
        return sections.joined(separator: "\n\n")
    }
}

enum PackageInstallState: Equatable {
    case idle
    case installing(String)
    case succeeded(String)
    case failed(String)

    var isInstalling: Bool {
        if case .installing = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .idle: return nil
        case .installing(let name): return "正在安装 \(name)…"
        case .succeeded(let name): return "\(name) 已安装并启动"
        case .failed(let message): return message
        }
    }
}

enum StreamQuality: String, CaseIterable, Identifiable, Sendable {
    case smooth
    case balanced
    case sharp
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smooth: return "流畅"
        case .balanced: return "均衡"
        case .sharp: return "清晰"
        case .original: return "原画"
        }
    }

    var maxLongEdge: Int? {
        switch self {
        case .smooth: return 960
        case .balanced: return 1360
        case .sharp: return 1920
        case .original: return nil
        }
    }

    var preferredFrameInterval: TimeInterval {
        switch self {
        case .smooth: return 0.10
        case .balanced: return 0.14
        case .sharp: return 0.20
        case .original: return 0.28
        }
    }

    func captureSize(for screen: CGSize) -> CGSize? {
        guard let maxLongEdge else { return nil }
        let longEdge = max(screen.width, screen.height)
        guard longEdge > CGFloat(maxLongEdge), longEdge > 0 else { return screen }
        let scale = CGFloat(maxLongEdge) / longEdge
        return CGSize(
            width: max(2, (screen.width * scale).rounded()),
            height: max(2, (screen.height * scale).rounded())
        )
    }
}

enum MirrorState: Equatable {
    case idle
    case connecting
    case streaming
    case paused
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "未连接"
        case .connecting: return "正在连接"
        case .streaming: return "投屏中"
        case .paused: return "已暂停"
        case .failed: return "连接异常"
        }
    }
}

enum SystemRecordingState: Equatable {
    case idle
    case starting
    case recording
    case stopping
    case failed(String)

    var isRecording: Bool {
        switch self {
        case .starting, .recording, .stopping: return true
        case .idle, .failed: return false
        }
    }

    var canToggle: Bool {
        switch self {
        case .idle, .recording, .failed: return true
        case .starting, .stopping: return false
        }
    }
}

struct CapturedFrame: Sendable {
    let data: Data
    let latency: TimeInterval
    let sourceResolution: CGSize?
}

enum RemoteCommand: Sendable {
    case tap(CGPoint)
    case swipe(from: CGPoint, to: CGPoint, duration: TimeInterval)
    case touchDown(CGPoint)
    case touchMove(CGPoint)
    case touchUp(CGPoint)
    case scroll(at: CGPoint, deltaX: Double, deltaY: Double)
    case namedKey(String)
    case keyCode(Int)
    case keyCombination(Int, Int)
    case text(String)

    var isContinuousMotion: Bool {
        switch self {
        case .touchMove, .scroll: return true
        default: return false
        }
    }
}

enum GeometryMapper {
    static func aspectFitRect(contentSize: CGSize, in bounds: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func normalized(_ point: CGPoint, contentRect: CGRect) -> CGPoint? {
        guard contentRect.width > 0, contentRect.height > 0, contentRect.contains(point) else { return nil }
        return CGPoint(
            x: ((point.x - contentRect.minX) / contentRect.width).clamped01,
            y: (1 - (point.y - contentRect.minY) / contentRect.height).clamped01
        )
    }

    static func normalizedClamped(_ point: CGPoint, contentRect: CGRect) -> CGPoint? {
        guard contentRect.width > 0, contentRect.height > 0 else { return nil }
        return CGPoint(
            x: ((point.x - contentRect.minX) / contentRect.width).clamped01,
            y: (1 - (point.y - contentRect.minY) / contentRect.height).clamped01
        )
    }
}

struct MirrorStageLayout: Equatable {
    let canvasSize: CGSize
    let railWidth: CGFloat

    static func calculate(
        container: CGSize,
        contentSize: CGSize,
        railWidth: CGFloat = 56,
        spacing: CGFloat = 18,
        horizontalPadding: CGFloat = 24,
        verticalPadding: CGFloat = 22
    ) -> MirrorStageLayout {
        let usableWidth = Swift.max(1, container.width - horizontalPadding * 2 - railWidth - spacing)
        let usableHeight = Swift.max(1, container.height - verticalPadding * 2)
        let validContent = contentSize.width > 0 && contentSize.height > 0
            ? contentSize
            : CGSize(width: 1260, height: 2720)
        let aspect = validContent.width / validContent.height
        let width = Swift.min(usableWidth, usableHeight * aspect)
        let height = width / aspect
        return MirrorStageLayout(canvasSize: CGSize(width: width, height: height), railWidth: railWidth)
    }
}

extension CGFloat {
    var clamped01: CGFloat { Swift.min(1, Swift.max(0, self)) }
}
