import Foundation
import XCTest
@testable import CCReaperCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class CommandRunnerTests: XCTestCase {
    func testProcessRunnerPreservesExitStatusOutputAndEnvironment() async throws {
        let runner = ProcessCommandRunner()
        let invocation = CommandInvocation(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s' \"$CC_REAPER_TEST\"; printf 'warning' >&2; exit 7"],
            environment: ["CC_REAPER_TEST": "ready"],
            operation: "output command"
        )

        let result = try await runner.run(invocation)

        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.stdout, "ready")
        XCTAssertEqual(result.stderr, "warning")
    }

    func testProcessRunnerTerminatesTimedOutChild() async throws {
        let runner = ProcessCommandRunner()
        let invocation = CommandInvocation(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec sleep 5"],
            timeout: 0.1,
            operation: "test command"
        )

        do {
            _ = try await runner.run(invocation)
            XCTFail("Expected timeout")
        } catch let error as CommandRunnerError {
            XCTAssertEqual(error, .timedOut(operation: "test command", seconds: 0.1))
        }
    }

    func testProcessRunnerEscalatesWhenTimedOutChildIgnoresTerm() async throws {
        let runner = ProcessCommandRunner()
        let invocation = CommandInvocation(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            timeout: 0.1,
            operation: "term-resistant command"
        )
        let startedAt = Date()

        do {
            _ = try await runner.run(invocation)
            XCTFail("Expected timeout")
        } catch let error as CommandRunnerError {
            XCTAssertEqual(error, .timedOut(operation: "term-resistant command", seconds: 0.1))
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testProcessRunnerTerminatesEntireTimedOutProcessGroup() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-reaper-runner-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let childPIDURL = temporaryDirectory.appendingPathComponent("child-pid")
        let runner = ProcessCommandRunner()
        let childScript = "trap '' TERM; echo $$ > \"$1\"; while :; do :; done"
        let invocation = CommandInvocation(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "/bin/sh -c \"$1\" child \"$2\" & wait",
                "wrapper",
                childScript,
                childPIDURL.path
            ],
            timeout: 0.2,
            operation: "process tree command"
        )

        var reportedOrdinaryTimeout = false
        do {
            _ = try await runner.run(invocation)
            XCTFail("Expected timeout")
        } catch let error as CommandRunnerError {
            switch error {
            case .timedOut(operation: "process tree command", seconds: 0.2):
                reportedOrdinaryTimeout = true
            case .terminationFailed(operation: "process tree command"):
                break
            default:
                XCTFail("Unexpected runner error: \(error)")
            }
        }

        let childPID = try XCTUnwrap(Int32(String(contentsOf: childPIDURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let childStillExists = systemKill(childPID, 0) == 0
        XCTAssertFalse(
            reportedOrdinaryTimeout && childStillExists,
            "Runner must surface termination failure while a timed-out child PID still exists"
        )
    }

    private func systemKill(_ pid: Int32, _ signal: Int32) -> Int32 {
        #if canImport(Darwin)
        Darwin.kill(pid, signal)
        #elseif canImport(Glibc)
        Glibc.kill(pid, signal)
        #endif
    }
}
