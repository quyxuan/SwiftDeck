import Combine
import Foundation

/// Process resources are app-wide even though dashboard state belongs to each window.
@MainActor
final class ProjectOperationRegistry: ObservableObject {
    static let shared = ProjectOperationRegistry()
    @Published private var activeProjects = Set<UUID>()

    func isAvailable(_ id: UUID) -> Bool { !activeProjects.contains(id) }

    func acquire(_ id: UUID) -> Bool { activeProjects.insert(id).inserted }

    func release(_ id: UUID) { activeProjects.remove(id) }
}
