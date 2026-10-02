import SwiftUI

struct SimulatorDetailsView: View {
    @ObservedObject var model: DashboardViewModel
    let snapshot: SimulatorModel
    @Environment(\.dismiss) private var dismiss

    private var liveDevice: SimulatorModel? {
        model.simulators.first { $0.id == snapshot.id }
    }

    private var device: SimulatorModel { liveDevice ?? snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Device Details")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Form {
                LabeledContent("Name", value: device.name)
                LabeledContent("UDID", value: device.id.uuidString)
                LabeledContent("Runtime", value: device.runtime)
                LabeledContent("Status", value: liveDevice?.status.displayLabel ?? "Unavailable — no longer in the device list")
                if let activity = model.simulatorActivity(device.id) {
                    LabeledContent("Activity", value: activity)
                }
                LabeledContent("Storage", value: device.storageBytes.map {
                    ByteCountFormatter.string(fromByteCount: $0, countStyle: .decimal)
                } ?? "Unavailable")
                LabeledContent("Data path") {
                    Text(device.dataPath ?? "Unavailable")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            HStack {
                Button("Copy UDID") { model.performSimulatorAction(.copyUDID, on: device.id) }
                    .disabled(!model.canSimulatorAction(.copyUDID, on: device.id))
                Button("Copy Name") { model.performSimulatorAction(.copyName, on: device.id) }
                    .disabled(!model.canSimulatorAction(.copyName, on: device.id))
                Button("Reveal Data") { model.performSimulatorAction(.revealData, on: device.id) }
                    .disabled(!model.canSimulatorAction(.revealData, on: device.id))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600)
    }
}

struct SimulatorURLView: View {
    @ObservedObject var model: DashboardViewModel
    let snapshot: SimulatorModel
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @FocusState private var isURLFocused: Bool

    private var deviceName: String {
        model.simulators.first { $0.id == snapshot.id }?.name ?? snapshot.name
    }

    private var trimmedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasScheme: Bool {
        guard let url = URL(string: trimmedValue), let scheme = url.scheme else { return false }
        return !scheme.isEmpty
    }

    private var canOpen: Bool {
        hasScheme && model.canSimulatorAction(.openURL, on: snapshot.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open URL in \(deviceName)")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            TextField("URL", text: $value, prompt: Text("https://example.com or myapp://path"))
                .textFieldStyle(.roundedBorder)
                .focused($isURLFocused)
                .onSubmit(open)
            Text("Include a URL scheme, such as https:// or your app’s custom scheme. The simulator must be booted.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !trimmedValue.isEmpty && !hasScheme {
                Label("Enter a valid URL with a scheme.", systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open URL", action: open)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canOpen)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { isURLFocused = true }
    }

    private func open() {
        guard canOpen else { return }
        model.openURL(trimmedValue, on: snapshot.id)
        dismiss()
    }
}
