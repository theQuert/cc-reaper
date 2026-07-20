import Foundation
import XCTest
@testable import CCReaperCore

final class ProcessRuleStoreTests: XCTestCase {
    func testRulesPersistAtomicallyWithOwnerOnlyPermissions() async throws {
        try await Self.verifyRulesPersistAtomicallyWithOwnerOnlyPermissions()
    }

    @MainActor
    private static func verifyRulesPersistAtomicallyWithOwnerOnlyPermissions() throws {
        let layout = try makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let store = ProcessRuleStore(fileURL: layout.file)

        try store.setRule(policy: .protect, match: "my-worker")

        XCTAssertEqual(store.rules, [ProcessRule(policy: .protect, match: "my-worker")])
        XCTAssertEqual(try String(contentsOf: layout.file, encoding: .utf8), "protect\tmy-worker\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: layout.file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))

        let reloaded = ProcessRuleStore(fileURL: layout.file)
        XCTAssertEqual(reloaded.rules, store.rules)
    }

    func testSettingSameLiteralReplacesPolicyCaseInsensitively() async throws {
        try await Self.verifySettingSameLiteralReplacesPolicyCaseInsensitively()
    }

    @MainActor
    private static func verifySettingSameLiteralReplacesPolicyCaseInsensitively() throws {
        let layout = try makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let store = ProcessRuleStore(fileURL: layout.file)

        try store.setRule(policy: .protect, match: "My Worker")
        try store.setRule(policy: .cleanup, match: "my worker")

        XCTAssertEqual(store.rules, [ProcessRule(policy: .cleanup, match: "my worker")])
        XCTAssertEqual(store.policy(forCommand: "/opt/MY WORKER --serve"), .cleanup)
    }

    func testExternalConflictFailsClosedToProtectAndMalformedRowsAreIgnored() async throws {
        try await Self.verifyExternalConflictFailsClosedToProtectAndMalformedRowsAreIgnored()
    }

    @MainActor
    private static func verifyExternalConflictFailsClosedToProtectAndMalformedRowsAreIgnored() throws {
        let layout = try makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try FileManager.default.createDirectory(at: layout.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cleanup\tshared-worker\nprotect\tSHARED-WORKER\ninvalid\tignored\ncleanup\tx\n".utf8)
            .write(to: layout.file)

        let store = ProcessRuleStore(fileURL: layout.file)

        XCTAssertEqual(store.rules, [ProcessRule(policy: .protect, match: "SHARED-WORKER")])
        XCTAssertEqual(store.policy(forCommand: "shared-worker --serve"), .protect)
    }

    func testInvalidLiteralIsRejectedAndRemovingLastRuleDeletesFile() async throws {
        try await Self.verifyInvalidLiteralIsRejectedAndRemovingLastRuleDeletesFile()
    }

    @MainActor
    private static func verifyInvalidLiteralIsRejectedAndRemovingLastRuleDeletesFile() throws {
        let layout = try makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let store = ProcessRuleStore(fileURL: layout.file)

        XCTAssertThrowsError(try store.setRule(policy: .cleanup, match: "x"))
        XCTAssertThrowsError(try store.setRule(policy: .cleanup, match: "bad\tvalue"))
        try store.setRule(policy: .protect, match: "safe-worker")
        try store.removeRule(match: "SAFE-WORKER")

        XCTAssertTrue(store.rules.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.file.path))
    }

    func testFindingSuggestedRuleUsesBoundedCommandLiteralRatherThanDisplayLabel() async throws {
        try await Self.verifyFindingSuggestedRuleUsesBoundedCommandLiteralRatherThanDisplayLabel()
    }

    @MainActor
    private static func verifyFindingSuggestedRuleUsesBoundedCommandLiteralRatherThanDisplayLabel() throws {
        let command = "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing --user-data-dir=/tmp/puppeteer_dev_chrome_profile-123456789 --remote-debugging-port=0"
        let finding = Finding(
            pid: 42,
            ppid: 1,
            pgid: 42,
            family: "agent-browser",
            classification: .safeToReap,
            label: "Puppeteer Chrome",
            averageCPU: 1,
            maximumCPU: 2,
            rssMB: 50,
            samples: 1,
            elapsed: "03:00:00",
            reason: "fixture",
            suggestedAction: "fixture",
            command: command
        )

        let match = try XCTUnwrap(finding.suggestedRuleMatch)
        XCTAssertEqual(match, String(command.prefix(128)))
        XCTAssertEqual(match.count, 128)
        XCTAssertNotEqual(match, finding.label)
        XCTAssertTrue(command.lowercased().contains(match.lowercased()))
    }

    func testFindingSuggestedRuleStopsBeforeRedactedValueAndMatchesLiveCommand() async throws {
        try await Self.verifyFindingSuggestedRuleStopsBeforeRedactedValueAndMatchesLiveCommand()
    }

    func testFindingDisallowsCleanupRuleForCodexUIHelper() {
        let finding = Finding(
            pid: 44,
            ppid: 1,
            pgid: 44,
            family: "other",
            classification: .doNotKill,
            label: "Codex Computer Use",
            averageCPU: 1,
            maximumCPU: 2,
            rssMB: 50,
            samples: 1,
            elapsed: "03:00:00",
            reason: "protected UI helper",
            suggestedAction: "Do not terminate directly",
            command: "/Users/me/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService"
        )

        XCTAssertFalse(finding.allowsCustomCleanupRule)
        XCTAssertNotNil(finding.suggestedRuleMatch, "Always Protect can remain available")
    }

    @MainActor
    private static func verifyFindingSuggestedRuleStopsBeforeRedactedValueAndMatchesLiveCommand() throws {
        let visibleCommand = "node /opt/custom-worker.js --api-key [redacted] --serve"
        let liveCommand = "node /opt/custom-worker.js --api-key super-secret-value --serve"
        let finding = Finding(
            pid: 43,
            ppid: 1,
            pgid: 43,
            family: "other",
            classification: .askBeforeKill,
            label: "node",
            averageCPU: 1,
            maximumCPU: 2,
            rssMB: 50,
            samples: 1,
            elapsed: "03:00:00",
            reason: "fixture",
            suggestedAction: "fixture",
            command: visibleCommand
        )

        let match = try XCTUnwrap(finding.suggestedRuleMatch)
        XCTAssertEqual(match, "node /opt/custom-worker.js --api-key")
        XCTAssertFalse(match.contains("[redacted]"))
        XCTAssertTrue(liveCommand.lowercased().contains(match.lowercased()))
    }

    private static func makeLayout() throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-reaper-rules-\(UUID().uuidString)", isDirectory: true)
        return (root, root.appendingPathComponent("state/process-rules.tsv"))
    }
}
