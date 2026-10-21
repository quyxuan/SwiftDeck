import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum ProjectPickerMode: String, Identifiable {
    case switchProject, build

    var id: String { rawValue }
}

struct RunConflictConfirmation: Identifiable {
    let id: UUID
    let projectID: UUID
    let conflict: RunningAppConflict
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var projects: [ProjectModel]
    @Published private(set) var simulators: [SimulatorModel] = []
    @Published var selectedProjectID: UUID? {
        didSet {
            if let selectedProjectID, projectIndices[selectedProjectID] == nil {
                self.selectedProjectID = nil
            }
            if selectedProjectID != oldValue, !isUpdatingLocalSelection {
                workspaceStore?.selectProject(selectedProjectID)
            }
        }
    }
    @Published var projectPickerMode: ProjectPickerMode?
    @Published var projectImportSelection: ProjectImportSelection?
    @Published var simulatorDetails: SimulatorModel?
    @Published var simulatorConfirmation: SimulatorConfirmation?
    @Published var simulatorURLTarget: SimulatorModel?
    @Published private(set) var runningAppConfirmation: RunConflictConfirmation?
    @Published private(set) var embeddedSimulator: EmbeddedSimulatorSession?
    let simulatorLaunches = PassthroughSubject<UUID, Never>()
    @Published private(set) var isChangingEmbeddedSimulator = false
    @Published private(set) var isImporting = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var screenshotFeedback: (id: UUID, message: String)?
    @Published private var operations: [UUID: Operation] = [:]
    @Published private var isShuttingDown = false
    @Published private var isOpeningSimulator = false
    @Published private var cleanupBlockedProjects = Set<UUID>()
    @Published private var deviceTasks: [UUID: Task<Void, Never>] = [:]

    private let buildService: any BuildServiceProtocol
    private let simulatorService: any SimulatorServiceProtocol
    private let workspaceStore: WorkspaceStore?
    private var preservedSimulatorSelections: Set<UUID> = []
    private var isUpdatingLocalSelection = false
    private var nextGeneration = 0
    private var simulatorSnapshotRevisions: [UUID: Int] = [:]
    private var importTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var simulatorTask: Task<Void, Never>?
    private var shutdownTask: Task<Bool, Never>?
    private var embeddingTask: Task<Void, Never>?
    private var ownershipObservation: AnyCancellable?
    private var deviceOwnershipObservation: AnyCancellable?
    private var blockedDeviceLeases: [UUID: SimulatorOperationRegistry.Lease] = [:]
    private var pendingRunConflicts: [PendingRunConflict] = []
    private var projectIndices: [UUID: Int]
    private var logStores: [UUID: ProjectLogStore] = [:]
    private var pendingLogProjects = Set<UUID>()
    private var pendingIssues: [UUID: BoundedEntries<BuildIssue>] = [:]
    private var logFlushTask: Task<Void, Never>?
    private static let logLimit = 5_000

    private struct Operation {
        let generation: Int
        let task: Task<Void, Never>
        var label: String
        let simulatorLease: SimulatorOperationRegistry.Lease?
        var stopping = false
        var queuedIntent: Intent?
        var removing = false
    }

    private struct PendingRunConflict {
        let confirmation: RunConflictConfirmation
        let generation: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private enum Intent {
        case build, run, clean

        var label: String {
            switch self {
            case .build, .run: "Building"
            case .clean: "Cleaning"
            }
        }
    }

    init(
        projects: [ProjectModel] = [],
        buildService: (any BuildServiceProtocol)? = nil,
        simulatorService: (any SimulatorServiceProtocol)? = nil,
        selectedProjectID: UUID? = nil,
        workspaceStore: WorkspaceStore? = nil
    ) {
        self.workspaceStore = workspaceStore
        let projects = workspaceStore?.workspace.projects.map(\.project) ?? projects
        self.projects = projects
        self.projectIndices = Dictionary(uniqueKeysWithValues: projects.enumerated().map { ($0.element.id, $0.offset) })
        self.buildService = buildService ?? XcodeBuildService()
        self.simulatorService = simulatorService ?? CoreSimulatorService()
        if let workspaceStore {
            self.selectedProjectID = projects.first(where: { $0.id == workspaceStore.workspace.selectedProjectID })?.id
            preservedSimulatorSelections = Set(projects.map(\.id))
            errorMessage = workspaceStore.errorMessage
            for index in self.projects.indices where !FileManager.default.fileExists(atPath: self.projects[index].path) {
                let project = self.projects[index]
                let message = "Project unavailable at \(project.path). Reconnect its volume or restore it at this location, then build again. If it moved, remove this entry and import its new location."
                self.projects[index].status = .failed
                self.projects[index].issues = [
                    BuildIssue(severity: .error, message: message, file: project.path, line: 0)
                ]
            }
        } else {
            self.selectedProjectID = projects.first(where: { $0.id == selectedProjectID })?.id
                ?? projects.first?.id
        }
        ownershipObservation = ProjectOperationRegistry.shared.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        deviceOwnershipObservation = SimulatorOperationRegistry.shared.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    isolated deinit {
        for operation in operations.values { operation.task.cancel() }
        logFlushTask?.cancel()
        for pending in pendingRunConflicts { pending.continuation.resume(returning: false) }
        importTask?.cancel()
        refreshTask?.cancel()
        simulatorTask?.cancel()
        for task in deviceTasks.values { task.cancel() }
        embeddingTask?.cancel()
        let display = embeddedSimulator
        Task { await display?.close() }
    }

    var selectedProject: ProjectModel? {
        guard let selectedIndex else { return nil }
        return projects[selectedIndex]
    }

    var operationLabel: String? {
        guard let selectedProjectID else { return nil }
        return operations[selectedProjectID]?.label
    }

    var isStopping: Bool {
        guard let selectedProjectID else { return false }
        return operations[selectedProjectID]?.stopping == true
    }

    var hasActiveOperations: Bool {
        !operations.isEmpty || !deviceTasks.isEmpty || isImporting || isRefreshing || isOpeningSimulator
    }

    var canBuild: Bool {
        guard let project = selectedProject else { return false }
        if let operation = operations[project.id] {
            return !isShuttingDown && !operation.stopping && !operation.removing
                && project.schemes.contains(project.scheme)
                && project.configurations.contains(project.configuration)
        }
        return canBuildProject(project)
    }

    func canBuildProject(_ id: UUID) -> Bool {
        guard let index = projectIndices[id] else { return false }
        return canBuildProject(projects[index])
    }

    func canBuildProject(_ project: ProjectModel) -> Bool {
        return canStart(project) && project.schemes.contains(project.scheme)
            && project.configurations.contains(project.configuration)
    }

    var canRun: Bool {
        guard canBuild, let project = selectedProject else { return false }
        return simulators.contains {
            $0.id == project.selectedSimulatorID && isRunnable($0)
        }
    }

    var canStop: Bool {
        guard let selectedProjectID, let operation = operations[selectedProjectID] else { return false }
        return (!operation.stopping || operation.queuedIntent != nil) && !isShuttingDown
    }

    var canClean: Bool {
        guard let selectedProjectID else { return false }
        return canBuildProject(selectedProjectID)
    }
    var canRemove: Bool {
        guard let selectedProjectID else { return false }
        return !isShuttingDown && operations[selectedProjectID]?.removing != true
            && !cleanupBlockedProjects.contains(selectedProjectID)
    }
    var canUseTools: Bool { selectedProject != nil && !isShuttingDown }

    var canChooseProject: Bool { !isShuttingDown }

    func selectProject(_ id: UUID?) {
        guard canChooseProject else { return }
        selectedProjectID = id
    }

    func selectProject(at index: Int) {
        guard canChooseProject, projects.indices.contains(index) else { return }
        selectedProjectID = projects[index].id
    }

    func selectAdjacentProject(offset: Int) {
        guard canChooseProject, !projects.isEmpty, offset != 0 else { return }
        guard let selectedIndex else {
            selectedProjectID = offset > 0 ? projects.first?.id : projects.last?.id
            return
        }
        let destination = (selectedIndex + offset % projects.count + projects.count) % projects.count
        selectedProjectID = projects[destination].id
    }

    func showProjectPicker(_ mode: ProjectPickerMode) {
        guard canChooseProject else { return }
        projectPickerMode = mode
    }

    @discardableResult
    func chooseProject(_ id: UUID, build: Bool) -> Bool {
        guard canChooseProject, let index = projectIndices[id],
              !build || canBuildProject(id) else { return false }
        let project = projects[index]
        selectedProjectID = id
        if build { start(project, intent: .build) }
        projectPickerMode = nil
        return true
    }

    func dismissError() { errorMessage = nil }

    func setScheme(_ scheme: String) {
        guard let index = selectedIndex, projects[index].schemes.contains(scheme) else { return }
        projects[index].scheme = scheme
        workspaceStore?.setScheme(scheme, for: projects[index].id)
    }

    func setConfiguration(_ configuration: String) {
        guard let index = selectedIndex,
              projects[index].configurations.contains(configuration) else { return }
        projects[index].configuration = configuration
        workspaceStore?.setConfiguration(configuration, for: projects[index].id)
    }

    func setSimulator(_ id: UUID?) {
        guard let index = selectedIndex else { return }
        if let id {
            guard simulators.contains(where: { $0.id == id && $0.status != .unavailable }) else { return }
        }
        projects[index].selectedSimulatorID = id
        preservedSimulatorSelections.insert(projects[index].id)
        workspaceStore?.setSimulator(id, for: projects[index].id)
    }

    func selectSimulator(_ id: UUID) {
        guard !isShuttingDown, let simulator = simulators.first(where: { $0.id == id }) else { return }
        if selectedProject == nil {
            simulatorDetails = simulator
        } else if canSimulatorAction(.useDestination, on: id) {
            setSimulator(id)
        }
    }

    func simulatorActivity(_ id: UUID) -> String? {
        let operation = operations.values.first(where: { $0.simulatorLease?.deviceID == id })
        return SimulatorOperationRegistry.shared.activity(on: id, runLabel: operation?.label)
    }

    func canSimulatorAction(_ action: SimulatorDeviceAction, on id: UUID) -> Bool {
        guard !isShuttingDown, let simulator = simulators.first(where: { $0.id == id }) else { return false }
        let registry = SimulatorOperationRegistry.shared
        switch action {
        case .embed:
            guard !isChangingEmbeddedSimulator else { return false }
            if embeddedSimulator?.device.id == id { return true }
            return simulator.status == .booted && registry.canAcquire(.display, on: id)
                || simulator.status == .available && registry.canAcquire(.management, on: id)
        case .details, .copyUDID, .copyName: return true
        case .revealData:
            return simulator.dataPath != nil
        case .useDestination:
            return selectedProject != nil && simulator.status != .unavailable
        case .runProject:
            return canBuild && isRunnable(simulator)
        case .stopApp:
            return operations.values.contains { $0.simulatorLease?.deviceID == id && !$0.stopping }
        case .bootAndOpen:
            return simulator.status == .available && registry.canAcquire(.management, on: id)
                || simulator.status == .booted && registry.canAcquire(.utility, on: id)
        case .shutdown, .restart:
            return simulator.status == .booted && registry.canAcquire(.management, on: id)
        case .show, .screenshot, .openURL:
            return simulator.status == .booted && registry.canAcquire(.utility, on: id)
        }
    }

    var screenshotSimulatorID: UUID? {
        guard let id = embeddedSimulator?.device.id ?? selectedProject?.selectedSimulatorID,
              canSimulatorAction(.screenshot, on: id) else { return nil }
        return id
    }

    func takeScreenshot() {
        guard let id = screenshotSimulatorID else { return }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        let filename = "Simulator Screenshot \(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).png"
        startDeviceAction(.screenshot, on: id, destination: desktop.appendingPathComponent(filename))
    }

    func copyScreenshot() {
        guard let id = screenshotSimulatorID else { return }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Simulator Screenshot \(UUID().uuidString).png")
        startDeviceAction(.screenshot, on: id, destination: destination, copyToClipboard: true)
    }

    func dismissScreenshotFeedback(_ id: UUID) {
        if screenshotFeedback?.id == id { screenshotFeedback = nil }
    }

    func performSimulatorAction(_ action: SimulatorDeviceAction, on id: UUID) {
        guard canSimulatorAction(action, on: id),
              let simulator = simulators.first(where: { $0.id == id }) else { return }
        switch action {
        case .embed: openEmbeddedSimulator(simulator)
        case .details: simulatorDetails = simulator
        case .copyUDID: copyToPasteboard(id.uuidString)
        case .copyName: copyToPasteboard(simulator.name)
        case .revealData:
            if let path = simulator.dataPath {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
            }
        case .useDestination: setSimulator(id)
        case .runProject:
            setSimulator(id)
            run()
        case .stopApp:
            for projectID in operations.keys.filter({ operations[$0]?.simulatorLease?.deviceID == id }) {
                cancelOperation(projectID)
            }
        case .shutdown, .restart:
            simulatorConfirmation = SimulatorConfirmation(simulator: simulator, action: action)
        case .openURL: simulatorURLTarget = simulator
        case .screenshot:
            let panel = NSSavePanel()
            panel.title = "Save Simulator Screenshot"
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "\(simulator.name).png"
            panel.begin { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.startDeviceAction(.screenshot, on: id, destination: url)
            }
        case .bootAndOpen, .show:
            startDeviceAction(action, on: id)
        }
    }

    private func openEmbeddedSimulator(_ simulator: SimulatorModel) {
        guard embeddedSimulator?.device.id != simulator.id else { return }
        isChangingEmbeddedSimulator = true
        let previous = embeddedSimulator
        embeddingTask = Task { [weak self] in
            await previous?.close()
            guard let self else { return }
            defer {
                self.isChangingEmbeddedSimulator = false
                self.embeddingTask = nil
            }
            self.embeddedSimulator = nil
            guard !Task.isCancelled, !self.isShuttingDown else { return }
            do {
                self.embeddedSimulator = try EmbeddedSimulatorSession(device: simulator) { [weak self] in
                    Task { await self?.refreshSimulators() }
                }
            } catch {
                self.errorMessage = "Unable to embed simulator: \(error.localizedDescription)"
            }
        }
    }

    func closeEmbeddedSimulator() {
        guard !isChangingEmbeddedSimulator, let display = embeddedSimulator else { return }
        isChangingEmbeddedSimulator = true
        embeddingTask = Task { [weak self] in
            await display.close()
            self?.embeddedSimulator = nil
            self?.isChangingEmbeddedSimulator = false
            self?.embeddingTask = nil
        }
    }

    var canShutdownEmbeddedSimulator: Bool {
        guard !isShuttingDown, !isChangingEmbeddedSimulator,
              let display = embeddedSimulator, display.isReady, !display.isRotating else { return false }
        return SimulatorOperationRegistry.shared.canManageAfterDetachingDisplay(on: display.device.id)
    }

    /// Called only after the panel's device-specific shutdown confirmation.
    func shutdownEmbeddedSimulator() {
        guard canShutdownEmbeddedSimulator, let display = embeddedSimulator else { return }
        let deviceID = display.device.id
        isChangingEmbeddedSimulator = true
        embeddingTask = Task { [weak self] in
            await display.close()
            guard let self else { return }
            defer {
                self.isChangingEmbeddedSimulator = false
                self.embeddingTask = nil
            }
            self.embeddedSimulator = nil
            guard !Task.isCancelled, !self.isShuttingDown else { return }
            // A Run may have reserved this device while input/display cleanup awaited.
            guard self.canSimulatorAction(.shutdown, on: deviceID) else {
                self.errorMessage = "The simulator became busy. Its display was disconnected, but the device was not shut down."
                return
            }
            self.startDeviceAction(.shutdown, on: deviceID)
        }
    }

    func confirmSimulatorAction() {
        guard let confirmation = simulatorConfirmation else { return }
        simulatorConfirmation = nil
        guard confirmation.action == .shutdown || confirmation.action == .restart else { return }
        startDeviceAction(confirmation.action, on: confirmation.simulator.id)
    }

    func openURL(_ value: String, on id: UUID) {
        guard canSimulatorAction(.openURL, on: id) else { return }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace),
              let url = URL(string: value), let scheme = url.scheme, !scheme.isEmpty else {
            errorMessage = "Enter a complete URL including its scheme, such as https://example.com or myapp://screen."
            return
        }
        simulatorURLTarget = nil
        startDeviceAction(.openURL, on: id, destination: url)
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func isRunnable(_ simulator: SimulatorModel) -> Bool {
        (simulator.status == .available || simulator.status == .booted)
            && SimulatorOperationRegistry.shared.canAcquire(.run, on: simulator.id)
    }

    private func startDeviceAction(_ action: SimulatorDeviceAction, on id: UUID, destination: URL? = nil,
                                   copyToClipboard: Bool = false) {
        guard canSimulatorAction(action, on: id), deviceTasks[id] == nil else { return }
        let label: String
        let kind: SimulatorOperationRegistry.Kind
        switch action {
        case .bootAndOpen:
            let booted = simulators.first(where: { $0.id == id })?.status == .booted
            label = booted ? "Opening Simulator" : "Booting"
            kind = booted ? .utility : .management
        case .show: label = "Opening Simulator"; kind = .utility
        case .shutdown: label = "Shutting Down"; kind = .management
        case .restart: label = "Restarting"; kind = .management
        case .screenshot: label = copyToClipboard ? "Copying Screenshot" : "Saving Screenshot"; kind = .utility
        case .openURL: label = "Opening URL"; kind = .utility
        default: return
        }
        guard let lease = SimulatorOperationRegistry.shared.acquire(kind, on: id, label: label) else { return }
        if action == .screenshot { screenshotFeedback = nil }
        let service = simulatorService
        deviceTasks[id] = Task { [weak self] in
            defer {
                SimulatorOperationRegistry.shared.release(lease)
                self?.deviceTasks.removeValue(forKey: id)
            }
            var actionFailed = false
            do {
                try Task.checkCancellation()
                switch action {
                case .bootAndOpen:
                    if kind == .management { try await service.bootAndOpen(id) }
                    else { try await service.openSimulator(on: id) }
                case .show: try await service.openSimulator(on: id)
                case .shutdown: try await service.shutdown(id)
                case .restart: try await service.restart(id)
                case .screenshot:
                    guard let destination else { return }
                    defer {
                        if copyToClipboard { try? FileManager.default.removeItem(at: destination) }
                    }
                    try await service.screenshot(id, to: destination)
                    if copyToClipboard {
                        try Task.checkCancellation()
                        let image = try Data(contentsOf: destination)
                        NSPasteboard.general.clearContents()
                        guard NSPasteboard.general.setData(image, forType: .png) else {
                            throw NSError(domain: "SwiftDeck", code: 1, userInfo: [
                                NSLocalizedDescriptionKey: "Could not copy screenshot to clipboard."
                            ])
                        }
                    }
                case .openURL:
                    guard let destination else { return }
                    try await service.openURL(destination, on: id)
                default: return
                }
                try Task.checkCancellation()
                if action == .screenshot, self?.isShuttingDown == false {
                    self?.screenshotFeedback = (
                        UUID(), copyToClipboard ? "Screenshot copied to clipboard" : "Screenshot saved"
                    )
                }
            } catch {
                actionFailed = true
                if !Task.isCancelled && !(error is CancellationError) {
                    self?.errorMessage = "\(label) failed: \(error.localizedDescription)"
                }
            }
            guard !Task.isCancelled, self?.isShuttingDown == false else { return }
            // Publish only an inventory taken after this action, never an older refresh.
            SimulatorOperationRegistry.shared.invalidateInventory(on: id)
            let revision = SimulatorOperationRegistry.shared.revision(for: id)
            do {
                let inventory = try await service.loadSimulators()
                try Task.checkCancellation()
                guard let self, !self.isShuttingDown,
                      revision == SimulatorOperationRegistry.shared.revision(for: id) else { return }
                if let index = self.simulators.firstIndex(where: { $0.id == id }) {
                    if let simulator = inventory.first(where: { $0.id == id }) {
                        self.simulators[index] = simulator
                    } else {
                        self.simulators.remove(at: index)
                    }
                }
                self.simulatorSnapshotRevisions[id] = revision
            } catch {
                if !actionFailed && !Task.isCancelled && !(error is CancellationError) {
                    self?.errorMessage = "Unable to refresh simulator state: \(error.localizedDescription)"
                }
            }
        }
    }

    func build() {
        guard canBuild, let project = selectedProject else { return }
        if operations[project.id] != nil {
            cancelOperation(project.id)
            operations[project.id]?.queuedIntent = .build
        } else {
            start(project, intent: .build)
        }
    }

    func run() {
        guard canRun, let project = selectedProject else { return }
        if operations[project.id] != nil {
            cancelOperation(project.id)
            operations[project.id]?.queuedIntent = .run
        } else {
            start(project, intent: .run)
        }
    }

    func clean() {
        guard canClean, let project = selectedProject else { return }
        start(project, intent: .clean)
    }

    func stop() {
        guard canStop, let selectedProjectID else { return }
        cancelOperation(selectedProjectID)
    }

    func resolveRunningAppConflict(_ id: UUID, stopAndRun: Bool) {
        guard let index = pendingRunConflicts.firstIndex(where: { $0.confirmation.id == id }) else { return }
        let pending = pendingRunConflicts.remove(at: index)
        let projectID = pending.confirmation.projectID
        let accepted = stopAndRun && owns(projectID, generation: pending.generation)
        if accepted { operations[projectID]?.label = "Launching" }
        runningAppConfirmation = pendingRunConflicts.first?.confirmation
        pending.continuation.resume(returning: accepted)
    }

    func removeProject() {
        guard canRemove, let selectedProjectID else { return }
        if operations[selectedProjectID] != nil {
            operations[selectedProjectID]?.removing = true
            cancelOperation(selectedProjectID)
        } else {
            deleteProject(selectedProjectID)
        }
    }

    func addProject() {
        guard !isImporting, !isShuttingDown else { return }
        let panel = NSOpenPanel()
        panel.title = "Import a Project, Workspace, or Folder"
        panel.message = """
            Choose a .xcodeproj, .xcworkspace, or a folder containing them directly. \
            If several are found, you choose which to import. Only import projects you trust: \
            builds and Xcode-generated scheme discovery can execute code with your user permissions outside App Sandbox.
            """
        panel.prompt = "Trust and Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.folder] + ["xcodeproj", "xcworkspace"].compactMap { UTType(filenameExtension: $0) }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { await self?.prepareProjectImport(at: url) }
        }
    }

    func prepareProjectImport(at url: URL) async {
        guard !isImporting, !isShuttingDown, !Task.isCancelled else { return }
        projectImportSelection = nil
        isImporting = true
        let task = Task { [weak self] in
            do {
                let candidates = try await ProjectImportResolver.candidates(at: url)
                try Task.checkCancellation()
                guard let self else { return }
                self.isImporting = false
                self.importTask = nil
                guard !self.isShuttingDown else { return }
                if candidates.count == 1, let candidate = candidates.first {
                    await self.importProject(at: candidate)
                } else {
                    self.projectImportSelection = ProjectImportSelection(candidates: candidates)
                }
            } catch {
                self?.isImporting = false
                self?.importTask = nil
                if !Task.isCancelled && !(error is CancellationError) {
                    self?.errorMessage = "Unable to import project: \(error.localizedDescription)"
                }
            }
        }
        importTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func confirmProjectImport(at url: URL) {
        guard !isImporting, !isShuttingDown,
              projectImportSelection?.candidates.contains(url) == true else { return }
        projectImportSelection = nil
        Task { [weak self] in await self?.importProject(at: url) }
    }

    func importProject(at url: URL) async {
        guard !isImporting, !isShuttingDown, !Task.isCancelled else { return }
        isImporting = true
        let service = buildService
        let knownProjects = projects.map { (id: $0.id, path: $0.path) }
        let task = Task { [weak self] in
            defer {
                self?.isImporting = false
                self?.importTask = nil
            }
            do {
                try Task.checkCancellation()
                let paths = await Self.canonicalPaths([url.path] + knownProjects.map(\.path))
                try Task.checkCancellation()
                guard self?.isShuttingDown == false else { return }
                if let existing = knownProjects.enumerated().first(where: {
                    paths[$0.offset + 1] == paths[0] && self?.projectIndices[$0.element.id] != nil
                }) {
                    self?.selectedProjectID = existing.element.id
                    return
                }
                let canonicalURL = URL(fileURLWithPath: paths[0])
                var project = try await service.discoverProject(at: canonicalURL)
                project.path = await Self.canonicalPaths([project.path])[0]
                try Task.checkCancellation()
                guard let self, !self.isShuttingDown else { return }
                if let existing = knownProjects.enumerated().first(where: {
                    paths[$0.offset + 1] == project.path && self.projectIndices[$0.element.id] != nil
                }) {
                    self.selectedProjectID = existing.element.id
                    return
                }
                project.selectedSimulatorID = self.simulators.first(where: { $0.status != .unavailable })?.id
                project = self.workspaceStore?.add(project) ?? project
                if self.workspaceStore != nil {
                    self.preservedSimulatorSelections.insert(project.id)
                }
                self.projectIndices[project.id] = self.projects.count
                self.projects.append(project)
                self.selectedProjectID = project.id
            } catch {
                if !Task.isCancelled && !(error is CancellationError) {
                    self?.errorMessage = "Unable to import project: \(error.localizedDescription)"
                }
            }
        }
        importTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func refreshSimulators() async {
        guard !isRefreshing, !isShuttingDown, !Task.isCancelled else { return }
        isRefreshing = true
        let service = simulatorService
        let revision = SimulatorOperationRegistry.shared.revision
        let task = Task { [weak self] in
            defer {
                self?.isRefreshing = false
                self?.refreshTask = nil
            }
            do {
                try Task.checkCancellation()
                let simulators = try await service.loadSimulators()
                try Task.checkCancellation()
                guard let self, !self.isShuttingDown else { return }
                var inventory = simulators.compactMap { simulator -> SimulatorModel? in
                    if self.simulatorSnapshotRevisions[simulator.id, default: 0] > revision {
                        return self.simulators.first(where: { $0.id == simulator.id })
                    }
                    return simulator
                }
                for current in self.simulators where self.simulatorSnapshotRevisions[current.id, default: 0] > revision {
                    if !inventory.contains(where: { $0.id == current.id }) { inventory.append(current) }
                }
                self.simulators = inventory
                let fallback = inventory.first(where: { $0.status != .unavailable })?.id
                for index in self.projects.indices {
                    guard !self.preservedSimulatorSelections.contains(self.projects[index].id) else { continue }
                    if !inventory.contains(where: {
                        $0.id == self.projects[index].selectedSimulatorID && $0.status != .unavailable
                    }) {
                        self.projects[index].selectedSimulatorID = fallback
                    }
                }
            } catch {
                if !Task.isCancelled && !(error is CancellationError) {
                    self?.errorMessage = "Unable to refresh simulators: \(error.localizedDescription)"
                }
            }
        }
        refreshTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func openSimulator() {
        guard !isOpeningSimulator, !isShuttingDown else { return }
        isOpeningSimulator = true
        let service = simulatorService
        simulatorTask = Task { [weak self] in
            defer {
                self?.isOpeningSimulator = false
                self?.simulatorTask = nil
            }
            do {
                try Task.checkCancellation()
                try await service.openSimulator(on: nil)
            } catch {
                if !Task.isCancelled && !(error is CancellationError) {
                    self?.errorMessage = "Unable to open Simulator: \(error.localizedDescription)"
                }
            }
        }
    }

    func revealProject() {
        guard canUseTools, let project = selectedProject else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
    }

    @discardableResult
    func shutdown() async -> Bool {
        if let shutdownTask { return await shutdownTask.value }
        isShuttingDown = true
        projectPickerMode = nil
        projectImportSelection = nil
        simulatorConfirmation = nil
        simulatorURLTarget = nil
        simulatorDetails = nil
        let tasks = operations.values.map(\.task) + Array(deviceTasks.values)
            + [importTask, refreshTask, simulatorTask, embeddingTask].compactMap { $0 }
        for id in Array(operations.keys) { cancelOperation(id) }
        for task in tasks { task.cancel() }
        let task = Task { [self] in
            for task in tasks { await task.value }
            await embeddedSimulator?.close()
            embeddedSimulator = nil
            do {
                try await simulatorService.retryPendingCleanup()
                for index in projects.indices where cleanupBlockedProjects.contains(projects[index].id) {
                    projects[index].status = .stopped
                    ProjectOperationRegistry.shared.release(projects[index].id)
                }
                cleanupBlockedProjects.removeAll()
                for lease in blockedDeviceLeases.values { SimulatorOperationRegistry.shared.release(lease) }
                blockedDeviceLeases.removeAll()
                return true
            } catch {
                errorMessage = "Unable to close SwiftDeck: \(error.localizedDescription)"
                isShuttingDown = false
                return false
            }
        }
        shutdownTask = task
        let result = await task.value
        shutdownTask = nil
        return result
    }

    func resumeAfterCancelledShutdown() {
        isShuttingDown = false
    }

    private var selectedIndex: Int? {
        guard let selectedProjectID else { return nil }
        return projectIndices[selectedProjectID]
    }

    @concurrent
    private static func canonicalPaths(_ paths: [String]) async -> [String] {
        paths.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
                .standardizedFileURL.resolvingSymlinksInPath().path
        }
    }

    private func canStart(_ project: ProjectModel) -> Bool {
        !isShuttingDown && operations[project.id] == nil
            && project.status != .building && project.status != .running
            && ProjectOperationRegistry.shared.isAvailable(project.id)
            && !cleanupBlockedProjects.contains(project.id)
    }

    private func start(_ project: ProjectModel, intent: Intent) {
        guard let index = projectIndices[project.id] else { return }
        guard ProjectOperationRegistry.shared.acquire(project.id) else { return }
        let simulator = simulators.first(where: { $0.id == project.selectedSimulatorID })
        var simulatorLease: SimulatorOperationRegistry.Lease?
        if intent == .run {
            guard let simulator, isRunnable(simulator),
                  let lease = SimulatorOperationRegistry.shared.acquire(.run, on: simulator.id, label: "Running") else {
                ProjectOperationRegistry.shared.release(project.id)
                return
            }
            simulatorLease = lease
        }
        let context = BuildContext(
            projectID: project.id, projectName: project.name, projectPath: project.path,
            scheme: project.scheme, configuration: project.configuration,
            simulatorID: simulator?.id, simulatorName: simulator?.name
        )
        nextGeneration += 1
        let generation = nextGeneration
        projects[index].status = .building
        projects[index].issues.removeAll()
        appendLog(index, level: .info, message: "\(intent.label): \(context.scheme) · \(context.configuration).")
        let buildService = buildService
        let simulatorService = simulatorService
        let projectID = project.id
        let task = Task { [weak self] in
            var error: (any Error)?
            defer {
                let queued = self?.operations[projectID]?.queuedIntent
                self?.finish(projectID, generation: generation, intent: intent, error: error)
                if self?.cleanupBlockedProjects.contains(projectID) != true {
                    ProjectOperationRegistry.shared.release(projectID)
                    if let simulatorLease { SimulatorOperationRegistry.shared.release(simulatorLease) }
                    if let self, let queued, let index = self.projectIndices[projectID],
                       self.canBuildProject(self.projects[index]) {
                        let project = self.projects[index]
                        if queued == .build {
                            self.start(project, intent: .build)
                        } else if self.simulators.contains(where: {
                            $0.id == project.selectedSimulatorID && self.isRunnable($0)
                        }) {
                            self.start(project, intent: .run)
                        }
                    }
                }
            }
            let output: @MainActor (String) -> Void = { [weak self] line in
                self?.receiveOutput(line, projectID: projectID, generation: generation)
            }
            do {
                try Task.checkCancellation()
                if intent == .clean {
                    try await buildService.clean(context, onOutput: output)
                } else {
                    try await buildService.build(context, onOutput: output)
                    if !Task.isCancelled, self?.owns(projectID, generation: generation) == true {
                        ProjectIconStore.shared.invalidate(ProjectIconRequest(
                            projectID: context.projectID, projectPath: context.projectPath,
                            scheme: context.scheme, configuration: context.configuration
                        ))
                    }
                    if intent == .run, let simulatorID = context.simulatorID {
                        try Task.checkCancellation()
                        guard self?.owns(projectID, generation: generation) == true else { return }
                        let artifact = try await buildService.builtApplication(context)
                        try Task.checkCancellation()
                        guard self?.owns(projectID, generation: generation) == true else { return }
                        self?.operations[projectID]?.label = "Launching"
                        try await simulatorService.run(
                            artifact, on: simulatorID, onOutput: output,
                            onLaunch: { [weak self] pid in
                                guard let self, self.owns(projectID, generation: generation),
                                      let index = self.projectIndices[projectID] else { return }
                                self.projects[index].status = .running
                                self.operations[projectID]?.label = "Running"
                                SimulatorOperationRegistry.shared.invalidateInventory(on: simulatorID)
                                if let destinationIndex = self.simulators.firstIndex(where: { $0.id == simulatorID }) {
                                    self.simulators[destinationIndex].status = .booted
                                    self.simulatorSnapshotRevisions[simulatorID] =
                                        SimulatorOperationRegistry.shared.revision(for: simulatorID)
                                }
                                self.appendLog(index, level: .success, message: "Launched \(context.scheme) on \(context.simulatorName ?? simulatorID.uuidString) (PID \(pid)).")
                                self.simulatorLaunches.send(simulatorID)
                            },
                            onConflict: { [weak self] conflict in
                                let requestID = UUID()
                                return await withTaskCancellationHandler {
                                    await withCheckedContinuation { continuation in
                                        guard let self, !Task.isCancelled,
                                              self.owns(projectID, generation: generation) else {
                                            continuation.resume(returning: false)
                                            return
                                        }
                                        self.operations[projectID]?.label = "Awaiting Confirmation"
                                        self.pendingRunConflicts.append(PendingRunConflict(
                                            confirmation: RunConflictConfirmation(
                                                id: requestID, projectID: projectID, conflict: conflict
                                            ),
                                            generation: generation, continuation: continuation
                                        ))
                                        self.runningAppConfirmation = self.pendingRunConflicts.first?.confirmation
                                    }
                                } onCancel: { [weak self] in
                                    let model = self
                                    Task { @MainActor in
                                        model?.resolveRunningAppConflict(requestID, stopAndRun: false)
                                    }
                                }
                            }
                        )
                    }
                }
                try Task.checkCancellation()
            } catch let caught {
                error = caught
            }
        }
        operations[project.id] = Operation(
            generation: generation, task: task, label: intent.label, simulatorLease: simulatorLease
        )
    }

    private func owns(_ id: UUID, generation: Int) -> Bool {
        operations[id]?.generation == generation && operations[id]?.stopping == false && !isShuttingDown
    }

    private func cancelOperation(_ id: UUID) {
        guard let operation = operations[id] else { return }
        operations[id]?.queuedIntent = nil
        operations[id]?.stopping = true
        operations[id]?.label = "Stopping"
        operation.task.cancel()
        cancelRunningAppConflict(id, generation: operation.generation)
    }

    private func cancelRunningAppConflict(_ projectID: UUID, generation: Int) {
        guard let pending = pendingRunConflicts.first(where: {
            $0.confirmation.projectID == projectID && $0.generation == generation
        }) else { return }
        resolveRunningAppConflict(pending.confirmation.id, stopAndRun: false)
    }

    private func finish(_ id: UUID, generation: Int, intent: Intent, error: (any Error)?) {
        guard let operation = operations[id], operation.generation == generation,
              let index = projectIndices[id] else { return }
        defer { flushOutput(for: id) }
        cancelRunningAppConflict(id, generation: generation)
        operations.removeValue(forKey: id)
        if let error = error as? ToolchainError, case .cleanupFailed = error {
            cleanupBlockedProjects.insert(id)
            if let lease = operation.simulatorLease { blockedDeviceLeases[id] = lease }
            projects[index].status = .failed
            appendLog(index, level: .error, message: error.localizedDescription)
            errorMessage = "\(error.localizedDescription)\nClose this window again to retry cleanup. This project stays locked until cleanup succeeds."
            return
        }
        if operation.removing {
            deleteProject(id)
            return
        }
        if let error, !(error is CancellationError), !operation.stopping {
            projects[index].status = .failed
            appendLog(index, level: .error, message: error.localizedDescription)
        } else if operation.stopping || error is CancellationError {
            projects[index].status = .stopped
            appendLog(index, level: .info, message: "Operation stopped.")
        } else {
            projects[index].status = intent == .run ? .stopped : .idle
            appendLog(index, level: .success, message: intent == .run ? "Application exited." : (intent == .clean ? "Clean succeeded." : "Build succeeded."))
        }
    }

    private func deleteProject(_ id: UUID) {
        guard let index = projectIndices[id] else { return }
        let wasSelected = selectedProjectID == id
        workspaceStore?.remove(id)
        preservedSimulatorSelections.remove(id)
        projects.remove(at: index)
        projectIndices = Dictionary(uniqueKeysWithValues: projects.enumerated().map { ($0.element.id, $0.offset) })
        logStores.removeValue(forKey: id)
        pendingLogProjects.remove(id)
        pendingIssues.removeValue(forKey: id)
        isUpdatingLocalSelection = true
        if wasSelected {
            selectedProjectID = projects.isEmpty ? nil : projects[min(index, projects.count - 1)].id
        }
        isUpdatingLocalSelection = false
    }

    func logStore(for projectID: UUID) -> ProjectLogStore {
        if let store = logStores[projectID] { return store }
        let store = ProjectLogStore()
        logStores[projectID] = store
        return store
    }

    private func receiveOutput(_ line: String, projectID: UUID, generation: Int) {
        // Stopping still owns its final pipe drain. Only a completed/replaced generation is stale.
        guard operations[projectID]?.generation == generation,
              let index = projectIndices[projectID] else { return }
        var level: LogLevel = line.hasPrefix("error:") || line.contains(": error:") ? .error : .info
        if (line.contains("error:") || line.contains("warning:") || line.contains("note:")),
           let issue = BuildIssue.parse(line) {
            pendingIssues[projectID, default: BoundedEntries(limit: Self.logLimit)].append(issue)
            if issue.severity == .error { level = .error }
        }
        appendLog(index, level: level, message: line)
    }

    private func appendLog(_ index: Int, level: LogLevel, message: String) {
        let id = projects[index].id
        logStore(for: id).append(BuildLogEntry(level: level, message: message))
        pendingLogProjects.insert(id)
        guard logFlushTask == nil else { return }
        logFlushTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
            guard let self else { return }
            self.logFlushTask = nil
            for id in self.pendingLogProjects { self.flushOutput(for: id) }
        }
    }

    private func flushOutput(for id: UUID) {
        pendingLogProjects.remove(id)
        logStores[id]?.flush()
        if let issues = pendingIssues.removeValue(forKey: id), let index = projectIndices[id] {
            var retained = projects[index].issues
            let excess = retained.count + issues.count - Self.logLimit
            if excess > 0 { retained.removeFirst(min(excess, retained.count)) }
            retained.append(contentsOf: issues)
            projects[index].issues = retained
        }
        if pendingLogProjects.isEmpty {
            logFlushTask?.cancel()
            logFlushTask = nil
        }
    }
}
