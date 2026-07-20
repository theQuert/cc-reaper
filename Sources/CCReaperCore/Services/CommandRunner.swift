import Foundation
import CCReaperSpawn
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
            var processID: pid_t = 0
            var didSpawn = false
            var exitCode: Int32?

            do {
                try Self.spawn(
                    invocation,
                    stdoutDescriptor: stdoutHandle.fileDescriptor,
                    stderrDescriptor: stderrHandle.fileDescriptor,
                    processID: &processID
                )
                didSpawn = true
                let deadline = Date().addingTimeInterval(invocation.timeout)
                while exitCode == nil {
                    exitCode = try Self.poll(processID)
                    if exitCode != nil {
                        break
                    }
                    if Date() >= deadline {
                        await Self.stop(processGroup: processID)
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
                if didSpawn, exitCode == nil {
                    await Self.stop(processGroup: processID)
                }
                try? stdoutHandle.close()
                try? stderrHandle.close()
                throw error
            }

            let stdout = String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self)
            let stderr = String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
            return CommandResult(exitCode: exitCode ?? -1, stdout: stdout, stderr: stderr)
        }.value
    }

    private static func spawn(
        _ invocation: CommandInvocation,
        stdoutDescriptor: Int32,
        stderrDescriptor: Int32,
        processID: inout pid_t
    ) throws {
        let arguments = [invocation.executable.path] + invocation.arguments
        let environment = (invocation.environment ?? ProcessInfo.processInfo.environment)
            .map { "\($0.key)=\($0.value)" }
            .sorted()

        let result = invocation.executable.path.withCString { executable in
            withCStringArray(arguments) { argumentPointers in
                withCStringArray(environment) { environmentPointers in
                    ccr_spawn_process(
                        executable,
                        argumentPointers,
                        environmentPointers,
                        stdoutDescriptor,
                        stderrDescriptor,
                        &processID
                    )
                }
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers where pointer != nil {
                free(pointer)
            }
        }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    private static func poll(_ processID: pid_t) throws -> Int32? {
        var exitCode: Int32 = 0
        let result = ccr_poll_process(processID, &exitCode)
        if result == 1 {
            return exitCode
        }
        if result < 0 {
            let errorNumber = -result
            throw POSIXError(POSIXErrorCode(rawValue: errorNumber) ?? .EIO)
        }
        return nil
    }

    private static func stop(processGroup: pid_t) async {
        _ = ccr_signal_process_group(processGroup, SIGTERM)
        await waitForExit(processGroup, timeout: terminationGrace)

        if ccr_process_group_exists(processGroup) != 0 {
            _ = ccr_signal_process_group(processGroup, SIGKILL)
            await waitForExit(processGroup, timeout: killGrace)
        }
    }

    private static func waitForExit(_ processGroup: pid_t, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        var exitCode: Int32 = 0
        while Date() < deadline {
            _ = ccr_poll_process(processGroup, &exitCode)
            if ccr_process_group_exists(processGroup) == 0 {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
