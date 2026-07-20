import Foundation

public struct CommandInvocation: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]?

    public init(executable: URL, arguments: [String], environment: [String: String]? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning: Sendable {
    func run(_ invocation: CommandInvocation) async throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = invocation.executable
            process.arguments = invocation.arguments
            if let environment = invocation.environment {
                process.environment = environment
            }

            let captureRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("cc-reaper-command-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: captureRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: captureRoot) }

            let stdoutURL = captureRoot.appendingPathComponent("stdout")
            let stderrURL = captureRoot.appendingPathComponent("stderr")
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle

            do {
                try process.run()
                process.waitUntilExit()
                try stdoutHandle.close()
                try stderrHandle.close()
            } catch {
                try? stdoutHandle.close()
                try? stderrHandle.close()
                throw error
            }

            let stdout = String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self)
            let stderr = String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
            return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
        }.value
    }
}
