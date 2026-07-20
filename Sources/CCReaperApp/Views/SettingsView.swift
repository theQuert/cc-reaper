import CCReaperCore
import SwiftUI

struct SettingsView: View {
    @AppStorage(AppPreferenceKeys.scriptRoot) private var scriptRoot = AppDefaults.scriptRoot
    @AppStorage(AppPreferenceKeys.minimumCPU) private var minimumCPU = AppDefaults.minimumCPU
    @AppStorage(AppPreferenceKeys.refreshInterval) private var refreshInterval = AppDefaults.refreshInterval

    var body: some View {
        Form {
            Section("Integration") {
                TextField("Script root", text: $scriptRoot)
                    .textFieldStyle(.roundedBorder)
                Text("Expected files: cc-monitor.sh and claude-cleanup.sh")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Monitoring") {
                LabeledContent("Minimum reported CPU") {
                    TextField("Percent", value: $minimumCPU, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
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
                    scriptRoot = AppDefaults.scriptRoot
                    minimumCPU = AppDefaults.minimumCPU
                    refreshInterval = AppDefaults.refreshInterval
                }
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(width: 500, height: 310)
    }
}
