import Foundation
import XCTest
@testable import CCReaperCore

@MainActor
final class AppConfigurationTests: XCTestCase {
    func testAutomaticResolutionUsesSourceShellWhenInstallationIsIncomplete() throws {
        let layout = try makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try addScripts(to: layout.sourceShell)
        try addScripts(to: layout.installedRoot, names: ["claude-cleanup.sh"])

        let configuration = AppConfiguration(
            defaults: layout.defaults,
            homeDirectory: layout.home,
            bundleURL: layout.bundle
        )

        XCTAssertEqual(configuration.scriptRoot, layout.sourceShell.standardizedFileURL)
        XCTAssertEqual(
            configuration.logsRoot,
            layout.home.appendingPathComponent(".cc-reaper/logs", isDirectory: true).standardizedFileURL
        )
    }

    func testAutomaticResolutionPrefersCompleteInstallation() throws {
        let layout = try makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try addScripts(to: layout.sourceShell)
        try addScripts(to: layout.installedRoot)

        let configuration = AppConfiguration(
            defaults: layout.defaults,
            homeDirectory: layout.home,
            bundleURL: layout.bundle
        )

        XCTAssertEqual(configuration.scriptRoot, layout.installedRoot.standardizedFileURL)
    }

    func testExplicitOverrideWinsEvenWhenAutomaticRootsAreComplete() throws {
        let layout = try makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try addScripts(to: layout.sourceShell)
        try addScripts(to: layout.installedRoot)
        let override = layout.root.appendingPathComponent("custom", isDirectory: true)
        layout.defaults.set(override.path, forKey: AppPreferenceKeys.scriptRoot)

        let configuration = AppConfiguration(
            defaults: layout.defaults,
            homeDirectory: layout.home,
            bundleURL: layout.bundle
        )

        XCTAssertEqual(configuration.scriptRoot, override.standardizedFileURL)
    }

    func testEmptyOverrideRestoresAutomaticResolution() throws {
        let layout = try makeLayout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try addScripts(to: layout.sourceShell)
        layout.defaults.set("   ", forKey: AppPreferenceKeys.scriptRoot)

        let configuration = AppConfiguration(
            defaults: layout.defaults,
            homeDirectory: layout.home,
            bundleURL: layout.bundle
        )

        XCTAssertEqual(configuration.scriptRoot, layout.sourceShell.standardizedFileURL)
    }

    private func makeLayout() throws -> Layout {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-reaper-configuration-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let installedRoot = home.appendingPathComponent(".cc-reaper", isDirectory: true)
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        let sourceShell = repository.appendingPathComponent("shell", isDirectory: true)
        let bundle = repository
            .appendingPathComponent("dist", isDirectory: true)
            .appendingPathComponent("CCReaper.app", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let suite = "AppConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return Layout(
            root: root,
            home: home,
            installedRoot: installedRoot,
            sourceShell: sourceShell,
            bundle: bundle,
            defaults: defaults
        )
    }

    private func addScripts(
        to root: URL,
        names: [String] = ["cc-monitor.sh", "claude-cleanup.sh"]
    ) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in names {
            try Data("#!/bin/bash\n".utf8).write(to: root.appendingPathComponent(name))
        }
    }
}

private struct Layout {
    let root: URL
    let home: URL
    let installedRoot: URL
    let sourceShell: URL
    let bundle: URL
    let defaults: UserDefaults
}
