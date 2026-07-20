import Foundation
import XCTest
@testable import CCReaperCore

@MainActor
final class MonitorStoreTests: XCTestCase {
    func testRefreshPublishesReportAndFreshness() async throws {
        let report = try decodeFixture()
        let service = StubCLIService(scans: [.success(report)])
        let defaults = makeDefaults()
        let store = MonitorStore(service: service, defaults: defaults)

        await store.refresh()

        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(store.report, report)
        XCTAssertNotNil(store.lastUpdated)
        XCTAssertNil(store.errorMessage)
    }

    func testRefreshFailureClearsHealthyEvidenceAndShowsUnavailable() async {
        let service = StubCLIService(scans: [.failure(CLIServiceError.missingScript("cc-monitor.sh"))])
        let store = MonitorStore(service: service, defaults: makeDefaults())

        await store.refresh()

        XCTAssertNil(store.report)
        guard case .unavailable = store.state else {
            return XCTFail("Expected unavailable state")
        }
        XCTAssertTrue(store.errorMessage?.contains("cc-monitor.sh") == true)
    }

    func testCleanupReviewPreviewsBeforeConfirmationAndCancelNeverInvokesCleanup() async throws {
        let report = try decodeFixture()
        let service = StubCLIService(
            scans: [.success(report)],
            previewResults: [.success("dry-run")]
        )
        let store = MonitorStore(service: service, defaults: makeDefaults())

        await store.refresh()
        await store.prepareCleanupReview()
        XCTAssertTrue(store.isCleanupConfirmationRequested)
        store.cancelCleanupReview()

        XCTAssertFalse(store.isCleanupConfirmationRequested)
        let previewCallCount = await service.previewCallCount
        let cleanupCallCount = await service.cleanupCallCount
        XCTAssertEqual(previewCallCount, 1)
        XCTAssertEqual(cleanupCallCount, 0)
    }

    func testConfirmedCleanupInvokesExistingEngineOnceAndRefreshes() async throws {
        let report = try decodeFixture()
        let service = StubCLIService(
            scans: [.success(report), .success(report)],
            previewResults: [.success("dry-run")],
            cleanupResults: [.success("cleaned")]
        )
        let store = MonitorStore(service: service, defaults: makeDefaults())

        await store.refresh()
        let servicePreview = await service.previewCallCount
        XCTAssertEqual(servicePreview, 0)
        await store.prepareCleanupReview()
        await store.confirmCleanup()

        XCTAssertFalse(store.isCleanupConfirmationRequested)
        let previewCallCount = await service.previewCallCount
        let cleanupCallCount = await service.cleanupCallCount
        let scanCallCount = await service.scanCallCount
        XCTAssertEqual(previewCallCount, 1)
        XCTAssertEqual(cleanupCallCount, 1)
        XCTAssertEqual(scanCallCount, 2)
        XCTAssertEqual(store.actionOutput, "cleaned")
        XCTAssertEqual(store.report, report)
    }

    func testPreviewUsesDryRunServiceAndPublishesOutput() async {
        let service = StubCLIService(
            scans: [],
            previewResults: [.success("dry-run")]
        )
        let store = MonitorStore(service: service, defaults: makeDefaults())

        await store.previewCleanup()

        let previewCallCount = await service.previewCallCount
        let cleanupCallCount = await service.cleanupCallCount
        XCTAssertEqual(previewCallCount, 1)
        XCTAssertEqual(cleanupCallCount, 0)
        XCTAssertEqual(store.actionOutput, "dry-run")
    }

    func testFailedCleanupPreviewDoesNotPresentConfirmation() async throws {
        let report = try decodeFixture()
        let service = StubCLIService(
            scans: [.success(report)],
            previewResults: [.failure(CLIServiceError.commandFailed(exitCode: 9, message: "denied"))]
        )
        let store = MonitorStore(service: service, defaults: makeDefaults())

        await store.refresh()
        await store.prepareCleanupReview()

        XCTAssertFalse(store.isCleanupConfirmationRequested)
        XCTAssertTrue(store.actionError?.contains("denied") == true)
    }

    private func decodeFixture() throws -> MonitorReport {
        try JSONDecoder().decode(MonitorReport.self, from: Data(MonitorReportTests.fixture.utf8))
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "CCReaperCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(60.0, forKey: AppPreferenceKeys.refreshInterval)
        defaults.set(1.0, forKey: AppPreferenceKeys.minimumCPU)
        defaults.set("/tmp/cc-reaper-fixture", forKey: AppPreferenceKeys.scriptRoot)
        return defaults
    }
}

private actor StubCLIService: CLIServiceProviding {
    private var scans: [Result<MonitorReport, CLIServiceError>]
    private var previewResults: [Result<String, CLIServiceError>]
    private var cleanupResults: [Result<String, CLIServiceError>]
    private(set) var scanCallCount = 0
    private(set) var previewCallCount = 0
    private(set) var cleanupCallCount = 0

    init(
        scans: [Result<MonitorReport, CLIServiceError>],
        previewResults: [Result<String, CLIServiceError>] = [],
        cleanupResults: [Result<String, CLIServiceError>] = []
    ) {
        self.scans = scans
        self.previewResults = previewResults
        self.cleanupResults = cleanupResults
    }

    func scan(scriptRoot: URL, minimumCPU: Double) async throws -> MonitorReport {
        scanCallCount += 1
        return try scans.removeFirst().get()
    }

    func previewCleanup(scriptRoot: URL) async throws -> String {
        previewCallCount += 1
        return try previewResults.removeFirst().get()
    }

    func runCleanup(scriptRoot: URL) async throws -> String {
        cleanupCallCount += 1
        return try cleanupResults.removeFirst().get()
    }
}
