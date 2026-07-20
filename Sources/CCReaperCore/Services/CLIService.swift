import Foundation

public protocol CLIServiceProviding: Sendable {
    func scan(scriptRoot: URL, minimumCPU: Double) async throws -> MonitorReport
    func previewCleanup(scriptRoot: URL) async throws -> String
    func runCleanup(scriptRoot: URL) async throws -> String
}

public enum CLIServiceError: Error, Equatable, LocalizedError, Sendable {
    case missingScript(String)
    case commandFailed(exitCode: Int32, message: String)
    case invalidMonitorOutput(String)

    public var errorDescription: String? {
        switch self {
        case .missingScript(let name):
            return "Missing \(name). Run cc-reaper install.sh or correct the script root in Settings."
        case .commandFailed(let exitCode, let message):
            return "cc-reaper command failed (exit \(exitCode)): \(message)"
        case .invalidMonitorOutput(let message):
            return "cc-monitor returned invalid JSON: \(message)"
        }
    }
}

public struct CLIService: CLIServiceProviding, Sendable {
    private enum Timeout {
        static let scan: TimeInterval = 30
        static let preview: TimeInterval = 45
        static let cleanup: TimeInterval = 120
    }

    private let runner: any CommandRunning
    private let decoder: JSONDecoder

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
        self.decoder = JSONDecoder()
    }

    public func scan(scriptRoot: URL, minimumCPU: Double) async throws -> MonitorReport {
        let monitor = try requiredScript(named: "cc-monitor.sh", under: scriptRoot)
        let invocation = CommandInvocation(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                monitor.path,
                "--once",
                "--json",
                "--min-cpu",
                String(minimumCPU)
            ],
            timeout: Timeout.scan,
            operation: "monitor scan"
        )
        let result = try await runner.run(invocation)
        try requireSuccess(result)
        do {
            let report = try decoder.decode(MonitorReport.self, from: Data(result.stdout.utf8))
            guard report.mode == "once" else {
                throw CLIServiceError.invalidMonitorOutput("expected mode=once")
            }
            guard report.readOnly else {
                throw CLIServiceError.invalidMonitorOutput("monitor payload is not read-only")
            }
            guard report.sampleCount > 0 else {
                throw CLIServiceError.invalidMonitorOutput("sample_count must be positive")
            }
            return report
        } catch {
            throw CLIServiceError.invalidMonitorOutput(error.localizedDescription)
        }
    }

    public func previewCleanup(scriptRoot: URL) async throws -> String {
        let cleanup = try requiredScript(named: "claude-cleanup.sh", under: scriptRoot)
        return try await runShellFunction(
            program: #"source "$1"; claude-cleanup --dry-run"#,
            script: cleanup,
            timeout: Timeout.preview,
            operation: "cleanup preview"
        )
    }

    public func runCleanup(scriptRoot: URL) async throws -> String {
        let cleanup = try requiredScript(named: "claude-cleanup.sh", under: scriptRoot)
        return try await runShellFunction(
            program: #"source "$1"; claude-cleanup"#,
            script: cleanup,
            timeout: Timeout.cleanup,
            operation: "cleanup"
        )
    }

    private func runShellFunction(
        program: String,
        script: URL,
        timeout: TimeInterval,
        operation: String
    ) async throws -> String {
        let result = try await runner.run(CommandInvocation(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", program, "_", script.path],
            timeout: timeout,
            operation: operation
        ))
        try requireSuccess(result)
        let output = [result.stdout, result.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return output.isEmpty ? "Command completed successfully." : output
    }

    private func requireSuccess(_ result: CommandResult) throws {
        guard result.exitCode == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = !stderr.isEmpty ? stderr : (!stdout.isEmpty ? stdout : "No error output")
            throw CLIServiceError.commandFailed(exitCode: result.exitCode, message: message)
        }
    }

    private func requiredScript(named name: String, under root: URL) throws -> URL {
        let candidate = root.standardizedFileURL.appendingPathComponent(name, isDirectory: false)
        let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else {
            throw CLIServiceError.missingScript(name)
        }
        return candidate
    }
}
