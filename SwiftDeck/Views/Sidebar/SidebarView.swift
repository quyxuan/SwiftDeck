import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: DashboardViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SceneStorage("projectSectionExpanded") private var projectsExpanded = true
    @SceneStorage("simulatorSectionExpanded") private var simulatorsExpanded = true

    var body: some View {
        let bootedSimulators = model.simulators.filter { $0.status == .booted }
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.selectedProjectID }, set: model.selectProject)) {
                Section("Projects", isExpanded: expansionBinding($projectsExpanded)) {
                    ProjectListView(projects: model.projects, simulators: model.simulators)
                }
                Section(isExpanded: expansionBinding($simulatorsExpanded)) {
                    SimulatorListView(model: model, simulators: bootedSimulators)
                    if bootedSimulators.isEmpty {
                        Text(model.isRefreshing ? "Loading devices…" : "No running simulators")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                } header: {
                    Text("Simulators (\(bootedSimulators.count))")
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Button(action: model.addProject) { Image(systemName: "plus") }
                    .disabled(model.isImporting)
                    .help("Open a trusted Xcode project, workspace, or containing folder")
                    .accessibilityLabel("Open project")
                Button(action: model.removeProject) { Image(systemName: "minus") }
                    .disabled(!model.canRemove)
                    .help("Remove selected project")
                    .accessibilityLabel("Remove selected project")
                Spacer()
                if model.isImporting || model.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await model.refreshSimulators() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
                .help("Refresh simulators")
                .accessibilityLabel("Refresh simulators")
            }
            .buttonStyle(.borderless)
            .padding(12)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Simulator storage", systemImage: "internaldrive")
                    Spacer()
                }
                .font(.caption)
                SimulatorStorageSummary(simulators: model.simulators)
                    .equatable()
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
        }
    }

    private func expansionBinding(_ value: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue }, set: { expanded in
            var transaction = Transaction(animation: reduceMotion ? nil : DashboardMotion.expansion)
            transaction.disablesAnimations = reduceMotion
            withTransaction(transaction) { value.wrappedValue = expanded }
        })
    }
}

private struct SimulatorStorageSummary: View, Equatable {
    let simulators: [SimulatorModel]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.simulators.count == rhs.simulators.count
            && zip(lhs.simulators, rhs.simulators).allSatisfy { $0.storageBytes == $1.storageBytes }
    }

    var body: some View {
        Text(summary)
    }

    private var summary: String {
        var bytes: Int64 = 0
        var knownCount = 0
        for simulator in simulators {
            if let storageBytes = simulator.storageBytes {
                bytes += storageBytes
                knownCount += 1
            }
        }
        guard knownCount > 0 else { return "Storage unavailable" }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
        return knownCount == simulators.count ? "\(size) used by simulators" : "\(size) known usage"
    }
}
