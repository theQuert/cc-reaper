import AppKit
import CCReaperCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let launchConfiguration = AppLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if launchConfiguration.activatesForeground {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

@main
struct CCReaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = MonitorStore()

    var body: some Scene {
        WindowGroup("cc-reaper", id: "dashboard") {
            DashboardView(store: store)
                .frame(minWidth: 760, minHeight: 560)
                .task { store.start() }
        }
        .defaultSize(width: 900, height: 660)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Refresh Status") {
                    Task { await store.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.isBusy)
            }
        }

        MenuBarExtra("cc-reaper", systemImage: store.menuBarIcon) {
            MenuBarView(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
