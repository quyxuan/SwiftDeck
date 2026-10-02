import Foundation

struct ProjectModel: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var path: String
    var schemes: [String]
    var scheme: String
    var configurations: [String]
    var configuration: String
    var selectedSimulatorID: UUID?
    var status: ProjectStatus
    var issues: [BuildIssue]

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        schemes: [String],
        scheme: String,
        configurations: [String],
        configuration: String,
        selectedSimulatorID: UUID? = nil,
        status: ProjectStatus = .idle,
        issues: [BuildIssue] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.schemes = schemes
        self.scheme = scheme
        self.configurations = configurations
        self.configuration = configuration
        self.selectedSimulatorID = selectedSimulatorID
        self.status = status
        self.issues = issues
    }
}
