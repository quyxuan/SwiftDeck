import Foundation

struct RunningAppConflict: Equatable, Sendable {
    let bundleIdentifier: String
    let simulatorID: UUID
    let simulatorName: String
    let pid: Int32
}

@MainActor
protocol SimulatorServiceProtocol {
    func loadSimulators() async throws -> [SimulatorModel]
    func run(
        _ artifact: BuildArtifact,
        on simulatorID: UUID,
        onOutput: @escaping @MainActor (String) -> Void,
        onLaunch: @escaping @MainActor (Int32) -> Void,
        onConflict: @escaping @MainActor (RunningAppConflict) async -> Bool
    ) async throws
    func openSimulator(on simulatorID: UUID?) async throws
    func bootAndOpen(_ simulatorID: UUID) async throws
    func shutdown(_ simulatorID: UUID) async throws
    func restart(_ simulatorID: UUID) async throws
    func screenshot(_ simulatorID: UUID, to url: URL) async throws
    func openURL(_ url: URL, on simulatorID: UUID) async throws
    func retryPendingCleanup() async throws
}
