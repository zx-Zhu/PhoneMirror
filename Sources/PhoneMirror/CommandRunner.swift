import Foundation

struct CommandResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool

    var succeeded: Bool { status == 0 && !timedOut }
    var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

enum CommandRunner {
    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = 8
    ) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                return CommandResult(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
            }
            let outputReader = CommandPipeReader(stdoutPipe.fileHandleForReading)
            let errorReader = CommandPipeReader(stderrPipe.fileHandleForReading)

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                briefSleep(0.015)
            }

            let didTimeOut = process.isRunning
            if didTimeOut {
                process.terminate()
                let terminationDeadline = Date().addingTimeInterval(0.4)
                while process.isRunning && Date() < terminationDeadline {
                    briefSleep(0.01)
                }
                if process.isRunning { process.interrupt() }
            }
            process.waitUntilExit()

            let output = outputReader.wait()
            let error = errorReader.wait()
            return CommandResult(
                status: process.terminationStatus,
                stdout: String(decoding: output, as: UTF8.self),
                stderr: String(decoding: error, as: UTF8.self),
                timedOut: didTimeOut
            )
        }.value
    }

    private static func briefSleep(_ interval: TimeInterval) {
        Thread.sleep(forTimeInterval: interval)
    }
}

private final class CommandPipeReader: @unchecked Sendable {
    private static let byteLimit = 8 * 1_024 * 1_024
    private static let truncatedMarker = Data("\n[PhoneMirror：输出已截断]\n".utf8)
    private let group = DispatchGroup()
    private var data = Data()

    init(_ handle: FileHandle) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
                let remaining = Self.byteLimit - data.count
                if remaining > 0 { data.append(chunk.prefix(remaining)) }
                if chunk.count > remaining {
                    data.append(Self.truncatedMarker)
                    while let discarded = try? handle.read(upToCount: 65_536),
                          !discarded.isEmpty {}
                    break
                }
            }
            group.leave()
        }
    }

    func wait() -> Data {
        group.wait()
        return data
    }
}
