import AppKit
import Foundation

enum ClipboardFileStore {
    static func makeArtifactURL(
        prefix: String,
        extension fileExtension: String,
        root customRoot: URL? = nil
    ) throws -> URL {
        let root = customRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneMirror", isDirectory: true)
            .appendingPathComponent("Clipboard", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return root.appendingPathComponent("\(prefix)_\(formatter.string(from: Date())).\(fileExtension)")
    }

    @MainActor
    static func copyFile(_ url: URL, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.writeObjects([url as NSURL])
    }

    static func writePNG(_ image: NSImage) throws -> URL {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ClipboardFileError.imageEncodingFailed
        }
        let url = try makeArtifactURL(prefix: "PhoneMirror_Screenshot", extension: "png")
        try png.write(to: url, options: .atomic)
        return url
    }
}

enum ClipboardFileError: LocalizedError {
    case imageEncodingFailed
    case clipboardWriteFailed

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed: return "截图文件生成失败"
        case .clipboardWriteFailed: return "文件写入剪贴板失败"
        }
    }
}
