import CCReaperCore
import SwiftUI

struct SettingsView: View {
    @Bindable var ruleStore: ProcessRuleStore
    let onRulesChanged: () -> Void

    @AppStorage(AppPreferenceKeys.scriptRoot) private var scriptRootOverride = ""
    @AppStorage(AppPreferenceKeys.minimumCPU) private var minimumCPU = AppDefaults.minimumCPU
    @AppStorage(AppPreferenceKeys.refreshInterval) private var refreshInterval = AppDefaults.refreshInterval
    @State private var newPolicy: ProcessRulePolicy = .protect
    @State private var newMatch = ""
    @State private var ruleError: String?

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("General", systemImage: "gearshape") }
            processRulesSettings
                .tabItem { Label("Process Rules", systemImage: "shield.lefthalf.filled") }
        }
        .scenePadding()
        .frame(width: 620, height: 430)
        .alert("Could not update process rules", isPresented: ruleErrorBinding) {
            Button("OK", role: .cancel) { ruleError = nil }
        } message: {
            Text(ruleError ?? "The process rule could not be saved.")
        }
    }

    private var generalSettings: some View {
        Form {
            Section("Integration") {
                TextField("Script root override", text: $scriptRootOverride, prompt: Text("Automatic"))
                    .textFieldStyle(.roundedBorder)
                Text("Active root: \(AppConfiguration().scriptRoot.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Automatic prefers ~/.cc-reaper, then a staged source checkout. Expected files: cc-monitor.sh and claude-cleanup.sh")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Monitoring") {
                LabeledContent("Minimum reported CPU") {
                    HStack(spacing: 4) {
                        TextField("", value: $minimumCPU, format: .number)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text("%")
                    }
                }
                LabeledContent("Refresh interval") {
                    HStack {
                        Stepper("", value: $refreshInterval, in: 15...3600, step: 15)
                            .labelsHidden()
                        Text("\(Int(refreshInterval)) sec")
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    scriptRootOverride = ""
                    minimumCPU = AppDefaults.minimumCPU
                    refreshInterval = AppDefaults.refreshInterval
                }
            }
        }
        .formStyle(.grouped)
    }

    private var processRulesSettings: some View {
        Form {
            Section {
                Text("Rules use a case-insensitive literal substring of the process command. Always Protect wins conflicts.")
                    .font(.callout)
                Text("Allow Stale Cleanup never authorizes an immediate kill: the process must still be stale and detached, system and cc-reaper processes remain blocked, and cleanup still requires preview and confirmation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Add rule") {
                HStack(spacing: 10) {
                    Picker("Policy", selection: $newPolicy) {
                        ForEach(ProcessRulePolicy.allCases, id: \.self) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)

                    TextField("Literal match", text: $newMatch)
                        .textFieldStyle(.roundedBorder)

                    Button("Add") { addRule() }
                        .disabled(ProcessRuleStore.normalizedMatch(newMatch) == nil)
                }
            }

            Section("Custom rules") {
                if ruleStore.rules.isEmpty {
                    ContentUnavailableView(
                        "No custom process rules",
                        systemImage: "shield",
                        description: Text("Built-in safety rules remain active.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 130)
                } else {
                    List(ruleStore.rules) { rule in
                        HStack(spacing: 10) {
                            Image(systemName: rule.policy == .protect ? "shield.fill" : "trash.slash")
                                .foregroundStyle(rule.policy == .protect ? Color.green : Color.orange)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.match)
                                    .font(.body.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(rule.policy.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { removeRule(rule) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(rule.match) rule")
                        }
                        .padding(.vertical, 3)
                    }
                    .frame(minHeight: 145, maxHeight: 180)
                }
            }

            Text("Stored at \(ruleStore.fileURL.path)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .formStyle(.grouped)
    }

    private var ruleErrorBinding: Binding<Bool> {
        Binding(
            get: { ruleError != nil },
            set: { visible in if !visible { ruleError = nil } }
        )
    }

    private func addRule() {
        do {
            try ruleStore.setRule(policy: newPolicy, match: newMatch)
            newMatch = ""
            onRulesChanged()
        } catch {
            ruleError = error.localizedDescription
        }
    }

    private func removeRule(_ rule: ProcessRule) {
        do {
            try ruleStore.removeRule(match: rule.match)
            onRulesChanged()
        } catch {
            ruleError = error.localizedDescription
        }
    }
}
