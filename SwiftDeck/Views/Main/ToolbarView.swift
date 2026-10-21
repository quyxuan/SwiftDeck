import SwiftUI

struct ToolbarView: View {
    @ObservedObject var model: DashboardViewModel
    let project: ProjectModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.headline)
                    Text(project.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : DashboardMotion.content, value: project.id)
                Spacer()
                HStack(spacing: 8) {
                    StatusBadgeView(status: project.status)
                    if let label = model.operationLabel {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                            .animation(reduceMotion ? nil : DashboardMotion.feedback, value: label)
                    }
                }
            }
            HStack(spacing: 10) {
                Picker("Scheme", selection: Binding(get: { project.scheme }, set: model.setScheme)) {
                    ForEach(project.schemes, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 170)
                Picker("Configuration", selection: Binding(
                    get: { project.configuration }, set: model.setConfiguration
                )) {
                    ForEach(project.configurations, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 190)
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
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: 8) {
                Button(action: model.build) {
                    Label(model.operationLabel == nil ? "Build" : "Rebuild", systemImage: "hammer")
                }
                .disabled(!model.canBuild).help("Build selected project (⌘B); while busy, cancel and rebuild")
                Button(action: model.run) {
                    Label(model.operationLabel == nil ? "Run" : "Rerun", systemImage: "play.fill")
                }
                .disabled(!model.canRun).help("Run selected project (⌘R); while busy, cancel and rerun")
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
            .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
