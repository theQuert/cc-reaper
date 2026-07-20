import AppKit
import CCReaperCore
import SwiftUI

struct DashboardView: View {
    @Bindable var store: MonitorStore
    @Bindable var ruleStore: ProcessRuleStore
    @State private var findingFilter: FindingFilter = .cleanup
    @State private var logsError: String?
    @State private var ruleError: String?
    @State private var showsAllSuggestedActions = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
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
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            cleanupActions
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
        }
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
            Text(cleanupConfirmationMessage)
        }
        .alert("Logs unavailable", isPresented: logsErrorBinding) {
            Button("OK", role: .cancel) { logsError = nil }
        } message: {
            Text(logsError ?? "The cc-reaper log directory is unavailable.")
        }
        .alert("Could not update process rule", isPresented: ruleErrorBinding) {
            Button("OK", role: .cancel) { ruleError = nil }
        } message: {
            Text(ruleError ?? "The process rule could not be saved.")
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
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(minimum: 150), spacing: 12, alignment: .leading),
                    count: 3
                ),
                spacing: 12
            ) {
                StatusCard(
                    title: "Cleanup candidates",
                    value: "\(report.safeCleanupCandidates.count)",
                    systemImage: "checkmark.shield",
                    tint: report.safeCleanupCandidates.isEmpty ? .green : .orange
                )
                StatusCard(
                    title: "Needs review",
                    value: "\(report.reviewFindings.count)",
                    systemImage: "exclamationmark.magnifyingglass",
                    tint: report.reviewFindings.isEmpty ? .secondary : .orange
                )
                StatusCard(
                    title: "Protected",
                    value: "\(report.protectedFindings.count)",
                    systemImage: "shield",
                    tint: .secondary
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
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Finding filter", selection: $findingFilter) {
                        ForEach(FindingFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: findingFilter) {
                        showsAllSuggestedActions = false
                    }

                    let filteredFindings = findingFilter.apply(to: report.findings)
                    if filteredFindings.isEmpty {
                        ContentUnavailableView(
                            findingFilter.emptyTitle,
                            systemImage: findingFilter.systemImage,
                            description: Text(findingFilter.emptyDescription)
                        )
                        .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        List(filteredFindings) { finding in
                            FindingRow(
                                finding: finding,
                                rule: ruleStore.rule(forCommand: finding.command),
                                onSetPolicy: { policy in setRule(policy, for: finding) },
                                onRemoveRule: { rule in removeRule(rule) }
                            )
                        }
                        .listStyle(.inset)
                        .frame(minHeight: 190, idealHeight: 240, maxHeight: 300)
                    }
                }
                .padding(.vertical, 4)
            }

            let actions = suggestedActions(for: report)
            if !actions.isEmpty {
                suggestedActions(actions)
            }
        } else if store.report != nil {
            ContentUnavailableView(
                "No reportable findings",
                systemImage: "checkmark.circle",
                description: Text("The latest read-only sample found nothing above the reporting threshold.")
            )
            .frame(maxWidth: .infinity, minHeight: 190)
        }
    }

    private var cleanupActions: some View {
        HStack {
            Button("Preview Cleanup") {
                Task { await store.previewCleanup() }
            }
            .disabled(store.isBusy)

            Button("Review & Confirm Cleanup…") {
                Task { await store.prepareCleanupReview() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusy || (store.report?.safeCleanupCandidates.isEmpty ?? true))

            Spacer()

            Text("Cleanup always requires confirmation")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func suggestedActions(_ actions: [String]) -> some View {
        let visibleActions = showsAllSuggestedActions ? actions : Array(actions.prefix(3))

        return GroupBox("Suggested next actions") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(visibleActions, id: \.self) { action in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "arrow.turn.down.right")
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(action)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if actions.count > 3 {
                    Button(showsAllSuggestedActions ? "Show fewer" : "Show \(actions.count - 3) more") {
                        withAnimation(.snappy) {
                            showsAllSuggestedActions.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityLabel(
                        showsAllSuggestedActions
                            ? "Show fewer suggested actions"
                            : "Show all \(actions.count) suggested actions"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func suggestedActions(for report: MonitorReport) -> [String] {
        let filteredFindings = findingFilter.apply(to: report.findings)
        guard !filteredFindings.isEmpty else { return [] }

        let contextual = filteredFindings.map(\.suggestedAction)
        let candidates = findingFilter == .all
            ? contextual + report.suggestedActions
            : contextual
        var seen = Set<String>()
        return candidates.filter { action in
            let normalized = action.trimmingCharacters(in: .whitespacesAndNewlines)
            return !normalized.isEmpty && seen.insert(normalized).inserted
        }
    }

    private var cleanupConfirmationMessage: String {
        let candidates = store.report?.safeCleanupCandidates ?? []
        let pids = candidates.prefix(8).map { String($0.pid) }.joined(separator: ", ")
        let suffix = candidates.count > 8 ? "…" : ""
        return "The latest read-only sample identified \(candidates.count) cleanup candidate(s) (PID \(pids)\(suffix)). cc-reaper will delegate once to the existing claude-cleanup engine, then refresh status. Active and protected processes remain governed by the existing safety rules."
    }

    private var logsErrorBinding: Binding<Bool> {
        Binding(
            get: { logsError != nil },
            set: { visible in
                if !visible { logsError = nil }
            }
        )
    }

    private var ruleErrorBinding: Binding<Bool> {
        Binding(
            get: { ruleError != nil },
            set: { visible in if !visible { ruleError = nil } }
        )
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
        let logs = store.configuration.logsRoot
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: logs.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            logsError = "The log directory is missing: \(logs.path)"
            return
        }
        guard NSWorkspace.shared.open(logs) else {
            logsError = "macOS could not open the log directory: \(logs.path)"
            return
        }
    }

    private func setRule(_ policy: ProcessRulePolicy, for finding: Finding) {
        guard let match = finding.suggestedRuleMatch else {
            ruleError = "This process name is too short for a safe literal rule. Add a longer command fragment in Settings."
            return
        }
        guard policy != .cleanup || finding.allowsCustomCleanupRule else {
            ruleError = "System, normal-browser, and cc-reaper processes cannot be added to cleanup."
            return
        }
        do {
            try ruleStore.setRule(policy: policy, match: match)
            Task { await store.refresh() }
        } catch {
            ruleError = error.localizedDescription
        }
    }

    private func removeRule(_ rule: ProcessRule) {
        do {
            try ruleStore.removeRule(match: rule.match)
            Task { await store.refresh() }
        } catch {
            ruleError = error.localizedDescription
        }
    }
}

private enum FindingFilter: String, CaseIterable, Identifiable {
    case cleanup
    case review
    case protected
    case all

    var id: Self { self }

    var title: String {
        switch self {
        case .cleanup: "Cleanup"
        case .review: "Review"
        case .protected: "Protected"
        case .all: "All"
        }
    }

    var systemImage: String {
        switch self {
        case .cleanup: "checkmark.shield"
        case .review: "exclamationmark.magnifyingglass"
        case .protected: "shield"
        case .all: "list.bullet"
        }
    }

    var emptyTitle: String {
        switch self {
        case .cleanup: "No cleanup candidates"
        case .review: "No manual-review findings"
        case .protected: "No protected findings"
        case .all: "No reportable findings"
        }
    }

    var emptyDescription: String {
        switch self {
        case .cleanup: "The latest sample found nothing safe for the existing cleanup engine to reap."
        case .review: "No findings currently require manual inspection."
        case .protected: "The latest sample found no protected processes above the reporting threshold."
        case .all: "The latest read-only sample found nothing above the reporting threshold."
        }
    }

    func apply(to findings: [Finding]) -> [Finding] {
        switch self {
        case .cleanup: findings.filter { $0.classification == .safeToReap }
        case .review: findings.filter { $0.classification == .askBeforeKill }
        case .protected: findings.filter { $0.classification == .doNotKill }
        case .all: findings
        }
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
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
    let rule: ProcessRule?
    let onSetPolicy: (ProcessRulePolicy) -> Void
    let onRemoveRule: (ProcessRule) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "circle.fill")
                .font(.caption2)
                .foregroundStyle(finding.classification.tint)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(finding.label)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Text("PID \(finding.pid)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Spacer(minLength: 8)
                    Text(finding.classification.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(finding.classification.tint)
                        .fixedSize()
                    processRuleMenu
                }
                Text(finding.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !finding.suggestedAction.isEmpty {
                    Text("Suggested: \(finding.suggestedAction)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("\(finding.averageCPU.formatted(.number.precision(.fractionLength(1))))% CPU · \(finding.rssMB) MB · \(finding.elapsed)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
    }

    private var processRuleMenu: some View {
        Menu {
            Button {
                onSetPolicy(.protect)
            } label: {
                Label(
                    rule?.policy == .protect ? "Always Protect (Current)" : "Always Protect",
                    systemImage: "shield.fill"
                )
            }
            .disabled(finding.suggestedRuleMatch == nil)

            Button {
                onSetPolicy(.cleanup)
            } label: {
                Label(
                    rule?.policy == .cleanup ? "Allow Stale Cleanup (Current)" : "Allow Stale Cleanup",
                    systemImage: "clock.badge.checkmark"
                )
            }
            .disabled(!finding.allowsCustomCleanupRule || finding.suggestedRuleMatch == nil)

            if let rule {
                Divider()
                Button("Remove Custom Rule", role: .destructive) {
                    onRemoveRule(rule)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(rule == nil ? Color.secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Process rule for \(finding.label)")
        .help("Manage protection or stale-cleanup policy")
    }
}
