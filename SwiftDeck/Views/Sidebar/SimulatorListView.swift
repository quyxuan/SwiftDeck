import SwiftUI

struct SimulatorListView: View {
    let model: DashboardViewModel
    private let simulators: [SimulatorModel]
    private let destinationID: UUID?
    private let activities: [UUID: String]

    init(model: DashboardViewModel, simulators: [SimulatorModel]) {
        self.model = model
        self.simulators = simulators
        destinationID = model.selectedProject?.selectedSimulatorID
        activities = Dictionary(
            simulators.compactMap { simulator in
                model.simulatorActivity(simulator.id).map { (simulator.id, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var body: some View {
        ForEach(simulators) { simulator in
            SimulatorRowView(
                model: model,
                simulator: simulator,
                activity: activities[simulator.id],
                isDestination: destinationID == simulator.id
            )
                .equatable()
                .selectionDisabled()
        }
    }
}
