import Combine
import Foundation

/// Durable project metadata only; processes, diagnostics and logs belong to a window.
struct SavedProject: Codable, Equatable {
    let id: UUID
    var name: String
    var path: String
    var schemes: [String]
    var scheme: String
    var configurations: [String]
    var configuration: String
    var selectedSimulatorID: UUID?

    init(_ project: ProjectModel) {
        id = project.id
        name = project.name
        path = project.path
        schemes = project.schemes
        scheme = project.scheme
        configurations = project.configurations
        configuration = project.configuration
        selectedSimulatorID = project.selectedSimulatorID
    }

    var project: ProjectModel {
        ProjectModel(id: id, name: name, path: path, schemes: schemes, scheme: scheme,
                     configurations: configurations, configuration: configuration,
                     selectedSimulatorID: selectedSimulatorID)
    }
}

struct SavedWorkspace: Codable, Equatable {
    var version = 1
    var projects: [SavedProject] = []
    var selectedProjectID: UUID?
}

/// One app-owned store accepts targeted mutations from independent windows.
/// Never save a window's entire list: a stale window must not remove another's imports
/// or resurrect projects removed elsewhere. Construction and window closing never write.
@MainActor
final class WorkspaceStore: ObservableObject {
    static let storageKey = "workspace.savedWorkspace"
    private(set) var workspace = SavedWorkspace()
    private(set) var errorMessage: String?
    private let defaults: UserDefaults
    private var canSave = true

    init(defaults: UserDefaults) {
        self.defaults = defaults
        guard let stored = defaults.object(forKey: Self.storageKey) else { return }
        do {
            guard let data = stored as? Data else { throw CocoaError(.coderReadCorrupt) }
            let saved = try JSONDecoder().decode(SavedWorkspace.self, from: data)
            guard saved.version == 1,
                  Set(saved.projects.map(\.id)).count == saved.projects.count,
                  Set(saved.projects.map(\.path)).count == saved.projects.count else {
                throw CocoaError(.coderReadCorrupt)
            }
            workspace = saved
        } catch {
            canSave = false
            errorMessage = "Unable to restore the saved workspace: \(error.localizedDescription) The saved data has been kept unchanged. Quit SwiftDeck and restore its preferences from a backup before importing projects."
        }
    }

    @discardableResult
    func add(_ project: ProjectModel) -> ProjectModel {
        if let existing = workspace.projects.first(where: { $0.path == project.path }) {
            return existing.project
        }
        guard !workspace.projects.contains(where: { $0.id == project.id }) else { return project }
        update { $0.projects.append(SavedProject(project)) }
        return project
    }

    func remove(_ id: UUID) {
        guard let index = workspace.projects.firstIndex(where: { $0.id == id }) else { return }
        update {
            $0.projects.remove(at: index)
            if $0.selectedProjectID == id {
                $0.selectedProjectID = $0.projects.isEmpty ? nil : $0.projects[min(index, $0.projects.count - 1)].id
            }
        }
    }

    func selectProject(_ id: UUID?) {
        guard id == nil || workspace.projects.contains(where: { $0.id == id }) else { return }
        update { $0.selectedProjectID = id }
    }

    func setScheme(_ scheme: String, for id: UUID) {
        guard let index = workspace.projects.firstIndex(where: { $0.id == id }),
              workspace.projects[index].schemes.contains(scheme) else { return }
        update { $0.projects[index].scheme = scheme }
    }

    func setConfiguration(_ configuration: String, for id: UUID) {
        guard let index = workspace.projects.firstIndex(where: { $0.id == id }),
              workspace.projects[index].configurations.contains(configuration) else { return }
        update { $0.projects[index].configuration = configuration }
    }

    func setSimulator(_ id: UUID?, for projectID: UUID) {
        guard let index = workspace.projects.firstIndex(where: { $0.id == projectID }) else { return }
        update { $0.projects[index].selectedSimulatorID = id }
    }

    private func update(_ mutation: (inout SavedWorkspace) -> Void) {
        guard canSave else { return }
        var next = workspace
        mutation(&next)
        guard next != workspace else { return }
        do {
            let data = try JSONEncoder().encode(next)
            defaults.set(data, forKey: Self.storageKey)
            workspace = next
        } catch {
            errorMessage = "Unable to save the workspace: \(error.localizedDescription)"
        }
    }
}
