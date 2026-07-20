import XCTest
@testable import CCReaperCore

final class MonitorReportTests: XCTestCase {
    func testDecodesMonitorJSONAndDerivesAttentionHealth() throws {
        let report = try JSONDecoder().decode(MonitorReport.self, from: Data(Self.fixture.utf8))

        XCTAssertTrue(report.readOnly)
        XCTAssertEqual(report.sampleCount, 1)
        XCTAssertEqual(report.findings.first?.label, "agent-browser")
        XCTAssertEqual(report.safeCleanupCandidates.map(\.pid), [37915])
        XCTAssertEqual(report.totalRSSMB, 768)
        XCTAssertEqual(report.totalCPU, 13.5, accuracy: 0.001)
        XCTAssertEqual(report.health, .attention)
    }

    func testRunawayEvidenceDerivesCriticalHealth() throws {
        let json = Self.fixture.replacingOccurrences(
            of: #""runaway_candidates": []"#,
            with: #""runaway_candidates": [{"pid": 42, "label": "node", "avg_cpu": 99.0, "etime": "02:00:00", "reason": "runaway"}]"#
        )

        let report = try JSONDecoder().decode(MonitorReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.health, .critical)
    }

    func testManualReviewFindingsDoNotMakeCleanupHealthAttention() throws {
        let json = Self.fixture
            .replacingOccurrences(of: "SAFE_TO_REAP", with: "ASK_BEFORE_KILL")
            .replacingOccurrences(
                of: #"{"pid": 37915, "family": "agent-browser", "avg_cpu": 1.5, "reason": "stale browser automation"}"#,
                with: ""
            )

        let report = try JSONDecoder().decode(MonitorReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.health, .healthy)
        XCTAssertEqual(report.reviewFindings.count, 1)
        XCTAssertEqual(report.protectedFindings.count, 0)
    }

    static let fixture = #"""
    {
      "sample_seconds": 0,
      "interval_seconds": 5,
      "sample_count": 1,
      "mode": "once",
      "read_only": true,
      "findings": [
        {
          "pid": 37915,
          "ppid": 1,
          "pgid": 37915,
          "family": "agent-browser",
          "classification": "SAFE_TO_REAP",
          "label": "agent-browser",
          "avg_cpu": 1.5,
          "max_cpu": 2.0,
          "rss_mb": 256,
          "samples": 1,
          "elapsed": "01:30:00",
          "reason": "stale browser automation",
          "suggested_action": "Run claude-cleanup",
          "command": "agent-browser-darwin-arm64"
        }
      ],
      "family_totals": [
        {"family": "agent-browser", "avg_cpu": 1.5, "rss_mb": 256, "processes": 1},
        {"family": "system", "avg_cpu": 12.0, "rss_mb": 512, "processes": 2}
      ],
      "safe_cleanup_candidates": [
        {"pid": 37915, "family": "agent-browser", "avg_cpu": 1.5, "reason": "stale browser automation"}
      ],
      "runaway_candidates": [],
      "suggested_actions": ["Run claude-cleanup"]
    }
    """#
}
