import Foundation

struct SimulatorModel: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var runtime: String
    var status: SimulatorStatus
    var storageBytes: Int64?
    var dataPath: String?

    init(
        id: UUID = UUID(),
        name: String,
        runtime: String,
        status: SimulatorStatus,
        storageBytes: Int64? = nil,
        dataPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.runtime = runtime
        self.status = status
        self.storageBytes = storageBytes
        self.dataPath = dataPath
    }
}

enum SimulatorDeviceAction: Sendable {
    case bootAndOpen, show, shutdown, restart, useDestination, runProject, stopApp
    case embed
    case screenshot, openURL, details, copyUDID, copyName, revealData
}

struct SimulatorConfirmation: Identifiable {
    let id = UUID()
    let simulator: SimulatorModel
    let action: SimulatorDeviceAction
}
