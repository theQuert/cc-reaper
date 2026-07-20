import Foundation

public enum AppPreferenceKeys {
    public static let scriptRoot = "ccReaper.scriptRoot"
    public static let minimumCPU = "ccReaper.minimumCPU"
    public static let refreshInterval = "ccReaper.refreshInterval"
}

public enum AppDefaults {
    public static let scriptRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cc-reaper", isDirectory: true)
        .path
    public static let minimumCPU = 1.0
    public static let refreshInterval = 60.0
}

public struct AppConfiguration: Equatable, Sendable {
    public let scriptRoot: URL
    public let logsRoot: URL
    public let minimumCPU: Double
    public let refreshInterval: Double

    @MainActor
    public init(
        defaults: UserDefaults = .standard,
        homeDirectory: URL? = nil,
        bundleURL: URL? = nil
    ) {
        let homeDirectory = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        let bundleURL = bundleURL ?? Bundle.main.bundleURL
        let storedRoot = defaults.string(forKey: AppPreferenceKeys.scriptRoot)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedRoot: URL

        if let storedRoot, !storedRoot.isEmpty {
            resolvedRoot = Self.expand(path: storedRoot, homeDirectory: homeDirectory)
        } else {
            let installedRoot = homeDirectory.appendingPathComponent(".cc-reaper", isDirectory: true)
            if Self.containsRequiredScripts(installedRoot) {
                resolvedRoot = installedRoot
            } else if let sourceRoot = Self.sourceRoot(for: bundleURL),
                      Self.containsRequiredScripts(sourceRoot) {
                resolvedRoot = sourceRoot
            } else {
                resolvedRoot = installedRoot
            }
        }

        let storedMinimumCPU = defaults.double(forKey: AppPreferenceKeys.minimumCPU)
        let storedRefreshInterval = defaults.double(forKey: AppPreferenceKeys.refreshInterval)
        self.scriptRoot = resolvedRoot.standardizedFileURL
        self.logsRoot = homeDirectory
            .appendingPathComponent(".cc-reaper", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .standardizedFileURL
        self.minimumCPU = storedMinimumCPU > 0 ? storedMinimumCPU : AppDefaults.minimumCPU
        self.refreshInterval = storedRefreshInterval > 0 ? storedRefreshInterval : AppDefaults.refreshInterval
    }

    private static func expand(path: String, homeDirectory: URL) -> URL {
        if path == "~" {
            return homeDirectory
        }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func sourceRoot(for bundleURL: URL) -> URL? {
        guard bundleURL.pathExtension == "app" else { return nil }
        let distDirectory = bundleURL.deletingLastPathComponent()
        guard distDirectory.lastPathComponent == "dist" else { return nil }
        return distDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("shell", isDirectory: true)
    }

    private static func containsRequiredScripts(_ root: URL) -> Bool {
        ["cc-monitor.sh", "claude-cleanup.sh"].allSatisfy { name in
            let candidate = root.appendingPathComponent(name, isDirectory: false)
            let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }
    }
}
