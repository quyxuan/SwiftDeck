import SwiftUI

struct ToolbarView: View {
    @ObservedObject var model: DashboardViewModel
    let project: ProjectModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(project.name).font(.title2.weight(.semibold))
                    Text(project.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : DashboardMotion.content, value: project.id)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    StatusBadgeView(status: project.status)
                    Text(model.operationLabel ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(height: 16)
                        .contentTransition(.opacity)
                        .animation(reduceMotion ? nil : DashboardMotion.feedback, value: model.operationLabel)
                }
            }
            HStack(spacing: 16) {
                Picker("Scheme", selection: Binding(get: { project.scheme }, set: model.setScheme)) {
                    ForEach(project.schemes, id: \.self) { Text($0).tag($0) }
                }
                Picker("Configuration", selection: Binding(
                    get: { project.configuration }, set: model.setConfiguration
                )) {
                    ForEach(project.configurations, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 210)
            }
            HStack(spacing: 16) {
                Picker("Destination", selection: Binding(
                    get: { project.selectedSimulatorID }, set: model.setSimulator
                )) {
                    Text("No destination").tag(Optional<UUID>.none)
                    if let savedID = project.selectedSimulatorID,
                       !model.simulators.contains(where: { $0.id == savedID }) {
                        Text(model.isRefreshing ? "Loading saved destination…" : "Saved destination unavailable")
                            .tag(Optional(savedID))
                            .disabled(true)
                    }
                    ForEach(model.simulators) { simulator in
                        Text(simulator.name).tag(Optional(simulator.id))
                            .disabled(simulator.status == .unavailable)
                    }
                }
            }
            HStack(spacing: 10) {
                Button(action: model.build) { Label("Build", systemImage: "hammer") }
                    .disabled(!model.canBuild).help("Build selected project (⌘B)")
                Button(action: model.run) { Label("Run", systemImage: "play.fill") }
                    .disabled(!model.canRun).help("Run selected project (⌘R)")
                Button(action: model.stop) { Label("Stop", systemImage: "stop.fill") }
                    .disabled(!model.canStop).help("Stop selected project (⌘.)")
                Button(action: model.clean) { Label("Clean", systemImage: "sparkles") }
                    .disabled(!model.canClean).help("Clean build folder (⇧⌘K)")
                Spacer()
                Menu {
                    Button("Reveal Project in Finder", action: model.revealProject)
                    if let simulatorID = project.selectedSimulatorID {
                        Button("Open in SwiftDeck") {
                            model.performSimulatorAction(.embed, on: simulatorID)
                        }
                        .disabled(!model.canSimulatorAction(.embed, on: simulatorID))
                    }
                    Button("Open Simulator (External)", action: model.openSimulator)
                    Button("Refresh Simulators") {
                        Task { await model.refreshSimulators() }
                    }
                    .disabled(model.isRefreshing)
                } label: {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                }
                .disabled(!model.canUseTools)
                .fixedSize()
                .help("Reveal project, open the embedded simulator, or refresh devices")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(24)
    }
}
