import SwiftUI

struct ProjectListView: View {
    let projects: [ProjectModel]
    let simulators: [SimulatorModel]

    var body: some View {
        let destinations = Dictionary(simulators.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        ForEach(projects) { project in
            ProjectRowView(
                name: project.name,
                status: project.status,
                destination: project.selectedSimulatorID.flatMap { destinations[$0] } ?? "No destination",
                iconRequest: ProjectIconRequest(
                    projectID: project.id, projectPath: project.path,
                    scheme: project.scheme, configuration: project.configuration
                )
            )
            .equatable()
            .tag(project.id)
        }
    }
}
