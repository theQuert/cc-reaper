import Foundation

public enum ProcessRulePolicy: String, CaseIterable, Codable, Equatable, Sendable {
    case protect
    case cleanup

    public var title: String {
        switch self {
        case .protect: "Always Protect"
        case .cleanup: "Allow Stale Cleanup"
        }
    }
}

public struct ProcessRule: Identifiable, Equatable, Sendable {
    public let policy: ProcessRulePolicy
    public let match: String

    public init(policy: ProcessRulePolicy, match: String) {
        self.policy = policy
        self.match = match
    }

    public var id: String { match.lowercased() }
}

public enum ProcessRuleError: LocalizedError, Equatable {
    case invalidMatch
    case persistenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidMatch:
            "Use a literal process-command match between 3 and 128 characters, without tabs or line breaks."
        case let .persistenceFailed(message):
            "Could not save process rules: \(message)"
        }
    }
}

public extension Finding {
    var allowsCustomCleanupRule: Bool {
        guard family != "system", family != "chrome" else { return false }
        let lowercasedCommand = command.lowercased()
        return !lowercasedCommand.contains("cc-monitor.sh")
            && !lowercasedCommand.contains("ccreaper.app/contents/macos/ccreaper")
            && !lowercasedCommand.contains("codex computer use.app")
            && !lowercasedCommand.contains("skycomputeruseservice")
            && label.lowercased() != "cc-reaper"
    }

    var suggestedRuleMatch: String? {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let stablePrefix: Substring
        if let redacted = command.range(of: "[redacted]", options: .caseInsensitive) {
            stablePrefix = command[..<redacted.lowerBound]
        } else {
            stablePrefix = command[...]
        }
        let candidate = String(stablePrefix.prefix(128))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ProcessRuleStore.normalizedMatch(candidate)
    }
}
