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

    func testNonReadOnlyMonitorPayloadIsRejected() async throws {
        let root = try makeScriptRoot(files: ["cc-monitor.sh"])
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingRunner(results: [
            CommandResult(exitCode: 0, stdout: MonitorReportTests.fixture.replacingOccurrences(of: #""read_only": true"#, with: #""read_only": false"#), stderr: "")
        ])
        let service = CLIService(runner: runner)

        do {
            _ = try await service.scan(scriptRoot: root, minimumCPU: 1)
            XCTFail("Expected non-read-only payload error")
        } catch let error as CLIServiceError {
            XCTAssertEqual(error, .invalidMonitorOutput("monitor payload is not read-only"))
            XCTAssertEqual(error.localizedDescription, "cc-monitor returned invalid JSON: monitor payload is not read-only")
        }
    }

    func testMonitorPayloadRequiresOnceModeAndPositiveSampleCount() async throws {
        let root = try makeScriptRoot(files: ["cc-monitor.sh"])
        defer { try? FileManager.default.removeItem(at: root) }

        let cases: [(from: String, to: String, message: String)] = [
            (#""mode": "once""#, #""mode": "sample""#, "expected mode=once"),
            (#""sample_count": 1"#, #""sample_count": 0"#, "sample_count must be positive")
        ]
        for testCase in cases {
            let runner = RecordingRunner(results: [
                CommandResult(exitCode: 0, stdout: MonitorReportTests.fixture.replacingOccurrences(of: testCase.from, with: testCase.to), stderr: "")
            ])
            let service = CLIService(runner: runner)
            do {
                _ = try await service.scan(scriptRoot: root, minimumCPU: 1)
                XCTFail("Expected monitor contract error")
            } catch let error as CLIServiceError {
                XCTAssertEqual(error, .invalidMonitorOutput(testCase.message))
                XCTAssertEqual(error.localizedDescription, "cc-monitor returned invalid JSON: \(testCase.message)")
            }
        }
    }

    func testPreviewAndCleanupUseFixedShellProgramsWithPathArgument() async throws {
        let root = try makeScriptRoot(files: ["claude-cleanup.sh"])
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingRunner(results: [
            CommandResult(exitCode: 0, stdout: "preview", stderr: "[DRY-RUN] Would kill PID 42"),
            CommandResult(exitCode: 0, stdout: "cleaned", stderr: "")
        ])
        let service = CLIService(runner: runner)

        let preview = try await service.previewCleanup(scriptRoot: root)
        let cleanup = try await service.runCleanup(scriptRoot: root)
        XCTAssertEqual(preview, "preview\n[DRY-RUN] Would kill PID 42")
        XCTAssertEqual(cleanup, "cleaned")

        let invocations = await runner.invocations
        let scriptPath = root.appendingPathComponent("claude-cleanup.sh").path
        XCTAssertEqual(invocations[0].arguments, [
            "-c", #"source "$1"; claude-cleanup --dry-run"#, "_", scriptPath
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
