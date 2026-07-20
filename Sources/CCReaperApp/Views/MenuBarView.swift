import AppKit
import CCReaperCore
import SwiftUI

struct MenuBarView: View {
    @Bindable var store: MonitorStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: store.menuBarIcon)
                    .font(.title2)
                    .foregroundStyle(store.statusTint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.statusTitle)
                        .font(.headline)
                    Text(lastUpdatedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let report = store.report {
                HStack {
                    metric("Cleanup", value: "\(report.safeCleanupCandidates.count)")
                    Divider()
                    metric("Review", value: "\(report.reviewFindings.count)")
                    Divider()
                    metric("Runaway", value: "\(report.runawayCandidates.count)")
                }
            } else if let error = store.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            Divider()

            Button("Refresh Status") {
                Task { await store.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store.isBusy)

            Button("Preview Cleanup") {
                openDashboard()
                Task { await store.previewCleanup() }
            }
            .disabled(store.isBusy)

            Button("Review Cleanup…") {
                Task {
                    await store.prepareCleanupReview()
                    openDashboard()
                }
            }
            .disabled(store.isBusy || (store.report?.safeCleanupCandidates.isEmpty ?? true))

            Divider()

            Button("Open Dashboard") {
                openDashboard()
            }

            SettingsLink {
                Text("Settings…")
            }

            Button("Quit cc-reaper") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var lastUpdatedText: String {
        guard let lastUpdated = store.lastUpdated else { return "No current evidence" }
        return "Updated \(lastUpdated.ccReaperTimestamp)"
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openDashboard() {
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
    }
}
