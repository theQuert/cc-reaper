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
    public let minimumCPU: Double
    public let refreshInterval: Double

    @MainActor
    public init(defaults: UserDefaults = .standard) {
        let storedRoot = defaults.string(forKey: AppPreferenceKeys.scriptRoot) ?? AppDefaults.scriptRoot
        let rootPath: String
        if storedRoot == "~" {
            rootPath = FileManager.default.homeDirectoryForCurrentUser.path
        } else if storedRoot.hasPrefix("~/") {
            rootPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(storedRoot.dropFirst(2)), isDirectory: true)
                .path
        } else {
            rootPath = storedRoot
        }

        let storedMinimumCPU = defaults.double(forKey: AppPreferenceKeys.minimumCPU)
        let storedRefreshInterval = defaults.double(forKey: AppPreferenceKeys.refreshInterval)
        self.scriptRoot = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        self.minimumCPU = storedMinimumCPU > 0 ? storedMinimumCPU : AppDefaults.minimumCPU
        self.refreshInterval = storedRefreshInterval > 0 ? storedRefreshInterval : AppDefaults.refreshInterval
    }
}
