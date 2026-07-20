import Foundation
import XCTest
@testable import CCReaperCore

@MainActor
final class ProcessRuleStoreTests: XCTestCase {
    func testRulesPersistAtomicallyWithOwnerOnlyPermissions() throws {
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

    func testSettingSameLiteralReplacesPolicyCaseInsensitively() throws {
        let layout = try makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let store = ProcessRuleStore(fileURL: layout.file)

        try store.setRule(policy: .protect, match: "My Worker")
        try store.setRule(policy: .cleanup, match: "my worker")

        XCTAssertEqual(store.rules, [ProcessRule(policy: .cleanup, match: "my worker")])
        XCTAssertEqual(store.policy(forCommand: "/opt/MY WORKER --serve"), .cleanup)
    }

    func testExternalConflictFailsClosedToProtectAndMalformedRowsAreIgnored() throws {
        let layout = try makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try FileManager.default.createDirectory(at: layout.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cleanup\tshared-worker\nprotect\tSHARED-WORKER\ninvalid\tignored\ncleanup\tx\n".utf8)
            .write(to: layout.file)

        let store = ProcessRuleStore(fileURL: layout.file)

        XCTAssertEqual(store.rules, [ProcessRule(policy: .protect, match: "SHARED-WORKER")])
        XCTAssertEqual(store.policy(forCommand: "shared-worker --serve"), .protect)
    }

    func testInvalidLiteralIsRejectedAndRemovingLastRuleDeletesFile() throws {
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

    private func makeLayout() throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-reaper-rules-\(UUID().uuidString)", isDirectory: true)
        return (root, root.appendingPathComponent("state/process-rules.tsv"))
    }
}
