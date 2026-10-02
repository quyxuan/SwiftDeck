import Foundation

struct BuildContext: Equatable, Sendable {
    let projectID: UUID
    let projectName: String
    let projectPath: String
    let scheme: String
    let configuration: String
    let simulatorID: UUID?
    let simulatorName: String?
}

struct BuildArtifact: Equatable, Sendable {
    let appURL: URL
    let bundleIdentifier: String
}

@MainActor
protocol BuildServiceProtocol {
    func discoverProject(at url: URL) async throws -> ProjectModel
    func build(
        _ context: BuildContext,
        onOutput: @escaping @MainActor (String) -> Void
    ) async throws
    func builtApplication(_ context: BuildContext) async throws -> BuildArtifact
    func clean(
        _ context: BuildContext,
        onOutput: @escaping @MainActor (String) -> Void
    ) async throws
}
