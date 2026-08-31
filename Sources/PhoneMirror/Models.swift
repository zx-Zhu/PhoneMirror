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
