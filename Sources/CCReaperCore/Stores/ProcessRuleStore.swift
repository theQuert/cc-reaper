import Foundation
import Observation

@MainActor
@Observable
public final class ProcessRuleStore {
    public private(set) var rules: [ProcessRule]

    @ObservationIgnored public let fileURL: URL
    @ObservationIgnored private let fileManager: FileManager

    public init(
        fileURL: URL = ProcessRuleStore.defaultFileURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
        self.rules = Self.loadRules(from: self.fileURL)
    }

    public static var defaultFileURL: URL {
        if let override = ProcessInfo.processInfo.environment["CC_REAPER_RULES_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: false)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cc-reaper", isDirectory: true)
            .appendingPathComponent("process-rules.tsv", isDirectory: false)
    }

    nonisolated public static func normalizedMatch(_ rawValue: String) -> String? {
        let match = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...128).contains(match.count),
              !match.contains("\t"),
              !match.contains("\n"),
              !match.contains("\r") else {
            return nil
        }
        return match
    }

    public func setRule(policy: ProcessRulePolicy, match rawMatch: String) throws {
        guard let match = Self.normalizedMatch(rawMatch) else {
            throw ProcessRuleError.invalidMatch
        }
        let key = match.lowercased()
        var updated = rules.filter { $0.match.lowercased() != key }
        updated.append(ProcessRule(policy: policy, match: match))
        try persist(updated)
        rules = Self.sorted(updated)
    }

    public func removeRule(match rawMatch: String) throws {
        let key = rawMatch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let updated = rules.filter { $0.match.lowercased() != key }
        guard updated != rules else { return }
        try persist(updated)
        rules = Self.sorted(updated)
    }

    public func rule(forCommand command: String) -> ProcessRule? {
        let lowercasedCommand = command.lowercased()
        return rules.first { rule in
            rule.policy == .protect && lowercasedCommand.contains(rule.match.lowercased())
        } ?? rules.first { rule in
            rule.policy == .cleanup && lowercasedCommand.contains(rule.match.lowercased())
        }
    }

    public func policy(forCommand command: String) -> ProcessRulePolicy? {
        rule(forCommand: command)?.policy
    }

    private func persist(_ rules: [ProcessRule]) throws {
        do {
            if rules.isEmpty {
                if fileManager.fileExists(atPath: fileURL.path) {
                    try fileManager.removeItem(at: fileURL)
                }
                return
            }

            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            let contents = Self.sorted(rules)
                .map { "\($0.policy.rawValue)\t\($0.match)\n" }
                .joined()
            try Data(contents.utf8).write(to: fileURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: fileURL.path
            )
        } catch let error as ProcessRuleError {
            throw error
        } catch {
            throw ProcessRuleError.persistenceFailed(error.localizedDescription)
        }
    }

    private static func loadRules(from fileURL: URL) -> [ProcessRule] {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        var byMatch: [String: ProcessRule] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2,
                  let policy = ProcessRulePolicy(rawValue: String(fields[0])),
                  let match = normalizedMatch(String(fields[1])) else {
                continue
            }
            let key = match.lowercased()
            if byMatch[key]?.policy == .protect { continue }
            if policy == .protect || byMatch[key] == nil {
                byMatch[key] = ProcessRule(policy: policy, match: match)
            }
        }
        return sorted(Array(byMatch.values))
    }

    private static func sorted(_ rules: [ProcessRule]) -> [ProcessRule] {
        rules.sorted {
            $0.match.localizedCaseInsensitiveCompare($1.match) == .orderedAscending
        }
    }
}
