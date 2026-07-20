import Foundation

public struct MonitorReport: Decodable, Equatable, Sendable {
    public let sampleSeconds: Int
    public let intervalSeconds: Int
    public let sampleCount: Int
    public let mode: String
    public let readOnly: Bool
    public let findings: [Finding]
    public let familyTotals: [FamilyTotal]
    public let safeCleanupCandidates: [CleanupCandidate]
    public let runawayCandidates: [RunawayCandidate]
    public let suggestedActions: [String]

    public var totalRSSMB: Int {
        familyTotals.reduce(0) { $0 + $1.rssMB }
    }

    public var totalCPU: Double {
        familyTotals.reduce(0) { $0 + $1.averageCPU }
    }

    public var health: MonitorHealth {
        if !runawayCandidates.isEmpty {
            return .critical
        }
        if !safeCleanupCandidates.isEmpty {
            return .attention
        }
        return .healthy
    }

    public var reviewFindings: [Finding] {
        findings.filter { $0.classification == .askBeforeKill }
    }

    public var protectedFindings: [Finding] {
        findings.filter { $0.classification == .doNotKill }
    }

    enum CodingKeys: String, CodingKey {
        case sampleSeconds = "sample_seconds"
        case intervalSeconds = "interval_seconds"
        case sampleCount = "sample_count"
        case mode
        case readOnly = "read_only"
        case findings
        case familyTotals = "family_totals"
        case safeCleanupCandidates = "safe_cleanup_candidates"
        case runawayCandidates = "runaway_candidates"
        case suggestedActions = "suggested_actions"
    }
}

public enum MonitorHealth: String, Equatable, Sendable {
    case healthy
    case attention
    case critical
}

public struct Finding: Decodable, Identifiable, Equatable, Sendable {
    public let pid: Int
    public let ppid: Int
    public let pgid: Int
    public let family: String
    public let classification: FindingClassification
    public let label: String
    public let averageCPU: Double
    public let maximumCPU: Double
    public let rssMB: Int
    public let samples: Int
    public let elapsed: String
    public let reason: String
    public let suggestedAction: String
    public let command: String

    public var id: Int { pid }

    enum CodingKeys: String, CodingKey {
        case pid, ppid, pgid, family, classification, label, samples, elapsed, reason, command
        case averageCPU = "avg_cpu"
        case maximumCPU = "max_cpu"
        case rssMB = "rss_mb"
        case suggestedAction = "suggested_action"
    }
}

public enum FindingClassification: String, Decodable, Equatable, Sendable {
    case safeToReap = "SAFE_TO_REAP"
    case askBeforeKill = "ASK_BEFORE_KILL"
    case doNotKill = "DO_NOT_KILL"
}

public struct FamilyTotal: Decodable, Identifiable, Equatable, Sendable {
    public let family: String
    public let averageCPU: Double
    public let rssMB: Int
    public let processes: Int

    public var id: String { family }

    enum CodingKeys: String, CodingKey {
        case family, processes
        case averageCPU = "avg_cpu"
        case rssMB = "rss_mb"
    }
}

public struct CleanupCandidate: Decodable, Identifiable, Equatable, Sendable {
    public let pid: Int
    public let family: String
    public let averageCPU: Double
    public let reason: String

    public var id: Int { pid }

    enum CodingKeys: String, CodingKey {
        case pid, family, reason
        case averageCPU = "avg_cpu"
    }
}

public struct RunawayCandidate: Decodable, Identifiable, Equatable, Sendable {
    public let pid: Int
    public let label: String
    public let averageCPU: Double
    public let elapsed: String
    public let reason: String

    public var id: Int { pid }

    enum CodingKeys: String, CodingKey {
        case pid, label, reason
        case averageCPU = "avg_cpu"
        case elapsed = "etime"
    }
}
