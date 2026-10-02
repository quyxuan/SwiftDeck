import SwiftUI

enum DashboardMotion {
    static let feedback = Animation.easeOut(duration: 0.10)
    static let content = Animation.smooth(duration: 0.18)
    static let expansion = Animation.smooth(duration: 0.22)
}

struct DashboardView: View {
    @ObservedObject var model: DashboardViewModel
    @State private var presentedSheet: DashboardSheet?
    @State private var dismissingSheet: DashboardSheet?

    var body: some View {
        let alert = alertPresentation
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
        } detail: {
            HSplitView {
                VStack(spacing: 0) {
                    if let project = model.selectedProject {
                        ToolbarView(model: model, project: project)
                        Divider()
                        IssuePanelView(issues: project.issues, status: project.status)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        BuildLogView(store: model.logStore(for: project.id), isExpanded: $model.isLogExpanded)
                            .id(project.id)
                    } else {
                        ContentUnavailableView {
                            Label("No Project Selected", systemImage: "square.stack.3d.up")
                        } description: {
                            Text("Open an Xcode project, workspace, or containing folder to build and run on an iOS Simulator.")
                        } actions: {
                            Button("Open Project…", action: model.addProject)
                                .disabled(model.isImporting)
                        }
                    }
                }
                .frame(minWidth: 460, idealWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
                if let session = model.embeddedSimulator {
                    EmbeddedSimulatorView(model: model, session: session)
                        .id(session.device.id)
                        .frame(minWidth: 420, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                        .disabled(model.isChangingEmbeddedSimulator)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("SwiftDeck")
        .navigationSubtitle("Local developer workspace")
        .frame(minWidth: model.embeddedSimulator == nil ? 900 : 1240, minHeight: 600)
        .task { await model.refreshSimulators() }
        .onReceive(model.simulatorLaunches) { simulatorID in
            model.performSimulatorAction(.embed, on: simulatorID)
        }
        .sheet(item: sheetBinding, onDismiss: sheetDidDismiss) { sheet in
            switch sheet {
            case .projectPicker(let mode):
                ProjectPickerView(model: model, mode: mode)
            case .projectImport(let selection):
                ProjectImportPickerView(
                    selection: selection,
                    onChoose: model.confirmProjectImport,
                    onCancel: { model.projectImportSelection = nil }
                )
            case .deviceDetails(let simulator):
                SimulatorDetailsView(model: model, snapshot: simulator)
            case .openURL(let simulator):
                SimulatorURLView(model: model, snapshot: simulator)
            case .runningApp(let confirmation):
                RunConflictConfirmationView(confirmation: confirmation) { stopAndRun in
                    model.resolveRunningAppConflict(confirmation.id, stopAndRun: stopAndRun)
                }
            }
        }
        .onChange(of: presentationRequests, initial: true) { _, _ in
            synchronizePresentations()
        }
        .alert(alert?.title ?? "SwiftDeck", isPresented: alertBinding(alert), presenting: alert) { presentation in
            switch presentation {
            case .error:
                Button("OK", role: .cancel) { model.dismissError() }
            case .confirmation(let confirmation):
                Button("Cancel", role: .cancel) { model.simulatorConfirmation = nil }
                Button(confirmation.action == .restart ? "Restart" : "Shut Down", role: .destructive) {
                    model.confirmSimulatorAction()
                }
                .disabled(!model.canSimulatorAction(confirmation.action, on: confirmation.simulator.id))
            }
        } message: { presentation in
            Text(presentation.message)
        }
    }

    private var pendingSheets: [DashboardSheet] {
        var sheets: [DashboardSheet] = []
        if let confirmation = model.runningAppConfirmation { sheets.append(.runningApp(confirmation)) }
        if let mode = model.projectPickerMode { sheets.append(.projectPicker(mode)) }
        if let selection = model.projectImportSelection { sheets.append(.projectImport(selection)) }
        if let simulator = model.simulatorDetails { sheets.append(.deviceDetails(simulator)) }
        if let simulator = model.simulatorURLTarget { sheets.append(.openURL(simulator)) }
        return sheets
    }

    private var presentationRequests: [String] {
        pendingSheets.map(\.id) + [
            model.errorMessage.map { "error:\($0)" } ?? "",
            model.simulatorConfirmation.map { "confirmation:\($0.id)" } ?? ""
        ]
    }

    private var sheetBinding: Binding<DashboardSheet?> {
        Binding(
            get: { presentedSheet },
            set: { value in
                guard value == nil, let current = presentedSheet else { return }
                dismissingSheet = current
                presentedSheet = nil
                clearSheetRequest(current)
            }
        )
    }

    private func synchronizePresentations() {
        if let current = presentedSheet {
            if !pendingSheets.contains(where: { $0.id == current.id }) {
                dismissingSheet = current
                presentedSheet = nil
            }
            return
        }
        guard dismissingSheet == nil, alertPresentation == nil else { return }
        presentedSheet = pendingSheets.first
    }

    private func sheetDidDismiss() {
        if let sheet = dismissingSheet ?? presentedSheet { clearSheetRequest(sheet) }
        presentedSheet = nil
        dismissingSheet = nil
        synchronizePresentations()
    }

    private func clearSheetRequest(_ sheet: DashboardSheet) {
        switch sheet {
        case .projectPicker(let mode):
            if model.projectPickerMode == mode { model.projectPickerMode = nil }
        case .projectImport(let selection):
            if model.projectImportSelection?.id == selection.id { model.projectImportSelection = nil }
        case .deviceDetails(let simulator):
            if model.simulatorDetails?.id == simulator.id { model.simulatorDetails = nil }
        case .openURL(let simulator):
            if model.simulatorURLTarget?.id == simulator.id { model.simulatorURLTarget = nil }
        case .runningApp(let confirmation):
            model.resolveRunningAppConflict(confirmation.id, stopAndRun: false)
        }
    }

    private var alertPresentation: DashboardAlert? {
        if let message = model.errorMessage { return .error(message) }
        if let confirmation = model.simulatorConfirmation { return .confirmation(confirmation) }
        return nil
    }

    private func alertBinding(_ alert: DashboardAlert?) -> Binding<Bool> {
        Binding(
            get: { alert != nil && presentedSheet == nil && dismissingSheet == nil },
            set: { isPresented in
                if !isPresented, let alert, case .error(let message) = alert, model.errorMessage == message {
                    model.dismissError()
                }
            }
        )
    }
}

private enum DashboardSheet: Identifiable {
    case projectPicker(ProjectPickerMode)
    case projectImport(ProjectImportSelection)
    case deviceDetails(SimulatorModel)
    case openURL(SimulatorModel)
    case runningApp(RunConflictConfirmation)

    var id: String {
        switch self {
        case .projectPicker(let mode): "picker:\(mode.id)"
        case .projectImport(let selection): "import:\(selection.id)"
        case .deviceDetails(let simulator): "details:\(simulator.id)"
        case .openURL(let simulator): "url:\(simulator.id)"
        case .runningApp(let confirmation): "running-app:\(confirmation.id)"
        }
    }
}

private enum DashboardAlert {
    case error(String)
    case confirmation(SimulatorConfirmation)

    var title: String {
        switch self {
        case .error: "SwiftDeck"
        case .confirmation(let confirmation):
            "\(confirmation.action == .restart ? "Restart" : "Shut Down") \(confirmation.simulator.name)?"
        }
    }

    var message: String {
        switch self {
        case .error(let message): message
        case .confirmation:
            "This stops all apps on this simulator, including apps launched by Xcode or other tools. This is a device-wide action, not Stop This Window’s App."
        }
    }
}

private struct RunConflictConfirmationView: View {
    let confirmation: RunConflictConfirmation
    let onChoice: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("App Already Running", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text("\(confirmation.conflict.bundleIdentifier) is already running on \(confirmation.conflict.simulatorName) outside this SwiftDeck session.")
                .textSelection(.enabled)
            Text("Stop that app and run the newly built version? Unsaved state in the running app may be lost. Saved app data and other apps are not removed.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onChoice(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Stop & Run Again", role: .destructive) { onChoice(true) }
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

#Preview("Dashboard") {
    DashboardView(model: DashboardViewModel())
}
