import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Form {
            Section("Automatic updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates }, set: updater.setAutomaticChecks
                ))
                Toggle("Download updates in the background", isOn: Binding(
                    get: { updater.automaticallyDownloadsUpdates }, set: updater.setAutomaticDownloads
                ))
                .disabled(!updater.automaticallyChecksForUpdates)
                Text("Checks run approximately once a day. Downloaded updates can install when you quit. Restarting to update waits until active work has finished.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Update status") {
                Text(updater.status)
                    .textSelection(.enabled)
                if let checked = updater.lastCheckDate {
                    LabeledContent("Last checked") {
                        Text(checked, format: .dateTime.month().day().hour().minute())
                    }
                } else {
                    LabeledContent("Last checked", value: "Not yet checked")
                }
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
                if updater.installationIsDeferred {
                    Button("Install and Restart", action: updater.resumeInstallation)
                    Text("Finish or stop running operations, then install. Other instances of this app must be closed first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Release channel") {
                LabeledContent("Channel", value: "Stable")
                Link("View GitHub Releases", destination: URL(string: "https://github.com/quyxuan/SwiftDeck-Releases/releases")!)
                Text("Update archives are verified with an Ed25519 signature before extraction. System profiling is disabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
