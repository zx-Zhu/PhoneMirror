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

            let output = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let error = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            return CommandResult(
                status: process.terminationStatus,
                stdout: String(data: output, encoding: .utf8) ?? "",
                stderr: String(data: error, encoding: .utf8) ?? "",
                timedOut: didTimeOut
            )
        }.value
    }

    private static func briefSleep(_ interval: TimeInterval) {
        Thread.sleep(forTimeInterval: interval)
    }
}
