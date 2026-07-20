import Foundation
import XCTest
@testable import CCReaperCore

final class CommandRunnerTests: XCTestCase {
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
}
