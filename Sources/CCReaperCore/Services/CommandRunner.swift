import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct CommandInvocation: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]?
    public let timeout: TimeInterval
    public let operation: String

    public init(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30,
        operation: String = "command"
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = max(0.1, timeout)
        self.operation = operation
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

public enum CommandRunnerError: Error, Equatable, LocalizedError, Sendable {
    case timedOut(operation: String, seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let operation, let seconds):
            return "cc-reaper \(operation) timed out after \(seconds.formatted(.number.precision(.fractionLength(1)))) seconds."
        }
    }
}

public struct ProcessCommandRunner: CommandRunning {
    private static let terminationGrace: TimeInterval = 0.25
    private static let killGrace: TimeInterval = 1

    public init() {}

    public func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) { () async throws -> CommandResult in
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
                let deadline = Date().addingTimeInterval(invocation.timeout)
                while process.isRunning {
                    if Date() >= deadline {
                        await Self.stop(process)
                        try? stdoutHandle.close()
                        try? stderrHandle.close()
                        throw CommandRunnerError.timedOut(
                            operation: invocation.operation,
                            seconds: invocation.timeout
                        )
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                try stdoutHandle.close()
                try stderrHandle.close()
            } catch {
                if process.isRunning {
                    await Self.stop(process)
                }
                try? stdoutHandle.close()
                try? stderrHandle.close()
                throw error
            }

            let stdout = String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self)
            let stderr = String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
            return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
        }.value
    }

    private static func stop(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        await waitForExit(process, timeout: terminationGrace)

        if process.isRunning {
            forceKill(process.processIdentifier)
            await waitForExit(process, timeout: killGrace)
        }

        if !process.isRunning {
            process.waitUntilExit()
        }
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func forceKill(_ pid: Int32) {
        #if canImport(Darwin)
        _ = Darwin.kill(pid, SIGKILL)
        #elseif canImport(Glibc)
        _ = Glibc.kill(pid, SIGKILL)
        #endif
    }
}
