import AppKit
import CCReaperCore
import SwiftUI

struct DashboardView: View {
    @Bindable var store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            summary

            if let error = store.errorMessage {
                errorBanner(error)
            }

            findings

            if store.actionTitle != nil {
                actionResult
            }
        }
        .padding(22)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isBusy)

                Button {
                    openLogs()
                } label: {
                    Label("Open Logs", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .alert("Clean up stale orphan processes?", isPresented: cleanupConfirmation) {
            Button("Cancel", role: .cancel) {
                store.cancelCleanupReview()
            }
            Button("Clean Up", role: .destructive) {
                Task { await store.confirmCleanup() }
            }
        } message: {
            Text("cc-reaper will delegate once to the existing claude-cleanup engine, then refresh status. Active and protected processes remain governed by the existing safety rules.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: store.menuBarIcon)
                .font(.system(size: 34))
                .foregroundStyle(store.statusTint)
            VStack(alignment: .leading, spacing: 4) {
                Text(store.statusTitle)
                    .font(.largeTitle.weight(.semibold))
                Text(freshnessText)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isBusy {
                ProgressView(activityLabel)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let report = store.report {
            HStack(spacing: 12) {
                StatusCard(
                    title: "Safe candidates",
                    value: "\(report.safeCleanupCandidates.count)",
                    systemImage: "checkmark.shield",
                    tint: report.safeCleanupCandidates.isEmpty ? .green : .orange
                )
                StatusCard(
                    title: "Reported CPU",
                    value: report.totalCPU.formatted(.number.precision(.fractionLength(1))) + "%",
                    systemImage: "cpu",
                    tint: .blue
                )
                StatusCard(
                    title: "Reported memory",
                    value: "\(report.totalRSSMB) MB",
                    systemImage: "memorychip",
                    tint: .purple
                )
                StatusCard(
                    title: "Runaway",
                    value: "\(report.runawayCandidates.count)",
                    systemImage: "flame",
                    tint: report.runawayCandidates.isEmpty ? .secondary : .red
                )
            }
        } else if store.state == .loading {
            ContentUnavailableView(
                "Collecting monitor evidence",
                systemImage: "waveform.path.ecg",
                description: Text("Running a read-only sample. This can take a few seconds.")
            )
            .frame(maxWidth: .infinity)
        } else {
            ContentUnavailableView(
                "No current monitor report",
                systemImage: "questionmark.circle",
                description: Text("Refresh after installing cc-reaper or correct the script root in Settings.")
            )
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var findings: some View {
        if let report = store.report, !report.findings.isEmpty {
            GroupBox("Current findings") {
                List(report.findings) { finding in
                    FindingRow(finding: finding)
                }
                .listStyle(.inset)
                .frame(minHeight: 190)
            }
        } else if store.report != nil {
            ContentUnavailableView(
                "No reportable findings",
                systemImage: "checkmark.circle",
                description: Text("The latest read-only sample found nothing above the reporting threshold.")
            )
            .frame(maxWidth: .infinity, minHeight: 190)
        }

        HStack {
            Button("Preview Cleanup") {
                Task { await store.previewCleanup() }
            }
            .disabled(store.isBusy)

            Button("Review Cleanup…") {
                store.requestCleanupReview()
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusy || (store.report?.safeCleanupCandidates.isEmpty ?? true))

            Spacer()

            Text("Cleanup always requires confirmation")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var actionResult: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(store.actionTitle ?? "Result")
                        .font(.headline)
                    Spacer()
                    Button {
                        store.clearActionResult()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss result")
                }
                ScrollView {
                    Text(store.actionError ?? store.actionOutput ?? "Running…")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(store.actionError == nil ? Color.primary : Color.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        }
    }

    private var cleanupConfirmation: Binding<Bool> {
        Binding(
            get: { store.isCleanupConfirmationRequested },
            set: { requested in
                if !requested { store.cancelCleanupReview() }
            }
        )
    }

    private var freshnessText: String {
        guard let lastUpdated = store.lastUpdated else {
            return "Waiting for read-only monitor evidence"
        }
        return "Last refreshed at \(lastUpdated.ccReaperTimestamp) · read-only sample"
    }

    private var activityLabel: String {
        switch store.activity {
        case .idle: "Ready"
        case .refreshing: "Refreshing"
        case .previewing: "Previewing"
        case .cleaning: "Cleaning"
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func openLogs() {
        let logs = store.configuration.scriptRoot.appendingPathComponent("logs", isDirectory: true)
        NSWorkspace.shared.open(logs)
    }
}

private struct StatusCard: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(tint)
                .font(.caption.weight(.medium))
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct FindingRow: View {
    let finding: Finding

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "circle.fill")
                .font(.caption2)
                .foregroundStyle(finding.classification.tint)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(finding.label)
                        .font(.headline)
                    Text("PID \(finding.pid)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(finding.classification.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(finding.classification.tint)
                }
                Text(finding.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("\(finding.averageCPU.formatted(.number.precision(.fractionLength(1))))% CPU · \(finding.rssMB) MB · \(finding.elapsed)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
    }
}
