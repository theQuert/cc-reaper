import Foundation
import XCTest
@testable import CCReaperCore

final class CLIServiceTests: XCTestCase {
    func testScanUsesReadOnlyMonitorInvocation() async throws {
        let root = try makeScriptRoot(files: ["cc-monitor.sh"])
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingRunner(results: [
            CommandResult(exitCode: 0, stdout: MonitorReportTests.fixture, stderr: "")
        ])
        let service = CLIService(runner: runner)

        let report = try await service.scan(scriptRoot: root, minimumCPU: 2.5)
        let recordedInvocations = await runner.invocations
        let invocation = try XCTUnwrap(recordedInvocations.first)

        XCTAssertEqual(report.sampleCount, 1)
        XCTAssertEqual(invocation.executable.path, "/bin/bash")
        XCTAssertEqual(invocation.arguments, [
            root.appendingPathComponent("cc-monitor.sh").path,
            "--once", "--json", "--min-cpu", "2.5"
        ])
    }

    func testMissingMonitorFailsClosedWithoutLaunchingCommand() async throws {
        let root = try makeScriptRoot(files: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingRunner(results: [])
        let service = CLIService(runner: runner)

        do {
            _ = try await service.scan(scriptRoot: root, minimumCPU: 1)
            XCTFail("Expected missing script error")
        } catch let error as CLIServiceError {
            XCTAssertEqual(error, .missingScript("cc-monitor.sh"))
        }
        let recordedInvocations = await runner.invocations
        XCTAssertTrue(recordedInvocations.isEmpty)
    }

    func testMalformedJSONIsUnavailableRatherThanHealthy() async throws {
        let root = try makeScriptRoot(files: ["cc-monitor.sh"])
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingRunner(results: [
            CommandResult(exitCode: 0, stdout: "not-json", stderr: "")
        ])
        let service = CLIService(runner: runner)

        do {
            _ = try await service.scan(scriptRoot: root, minimumCPU: 1)
            XCTFail("Expected invalid monitor output")
        } catch let error as CLIServiceError {
            guard case .invalidMonitorOutput = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPreviewAndCleanupUseFixedShellProgramsWithPathArgument() async throws {
        let root = try makeScriptRoot(files: ["claude-cleanup.sh"])
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingRunner(results: [
            CommandResult(exitCode: 0, stdout: "preview", stderr: ""),
            CommandResult(exitCode: 0, stdout: "cleaned", stderr: "")
        ])
        let service = CLIService(runner: runner)

        let preview = try await service.previewCleanup(scriptRoot: root)
        let cleanup = try await service.runCleanup(scriptRoot: root)
        XCTAssertEqual(preview, "preview")
        XCTAssertEqual(cleanup, "cleaned")

        let invocations = await runner.invocations
        let scriptPath = root.appendingPathComponent("claude-cleanup.sh").path
        XCTAssertEqual(invocations[0].arguments, [
            "-c", #"source "$1"; claude-guard --dry-run"#, "_", scriptPath
        ])
        XCTAssertEqual(invocations[1].arguments, [
            "-c", #"source "$1"; claude-cleanup"#, "_", scriptPath
        ])
    }

    func testNonzeroCommandPreservesFailureAndDoesNotRetry() async throws {
        let root = try makeScriptRoot(files: ["claude-cleanup.sh"])
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingRunner(results: [
            CommandResult(exitCode: 9, stdout: "", stderr: "denied")
        ])
        let service = CLIService(runner: runner)

        do {
            _ = try await service.runCleanup(scriptRoot: root)
            XCTFail("Expected delegated command failure")
        } catch let error as CLIServiceError {
            XCTAssertEqual(error, .commandFailed(exitCode: 9, message: "denied"))
        }
        let recordedInvocations = await runner.invocations
        XCTAssertEqual(recordedInvocations.count, 1)
    }

    private func makeScriptRoot(files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-reaper-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            try Data("#!/bin/bash\n".utf8).write(to: root.appendingPathComponent(file))
        }
        return root
    }
}

private actor RecordingRunner: CommandRunning {
    private(set) var invocations: [CommandInvocation] = []
    private var results: [CommandResult]

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        invocations.append(invocation)
        guard !results.isEmpty else {
            throw CLIServiceError.commandFailed(exitCode: -1, message: "No fixture result")
        }
        return results.removeFirst()
    }
}
