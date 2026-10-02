import SwiftUI

struct ProjectPickerView: View {
    @ObservedObject var model: DashboardViewModel
    let mode: ProjectPickerMode

    var body: some View {
        ProjectPickerContent(
            model: model,
            mode: mode,
            allProjects: model.projects.map {
                ProjectPickerRow(
                    id: $0.id, name: $0.name, path: $0.path, status: $0.status,
                    canBuild: mode == .build && model.canBuildProject($0)
                )
            },
            canChooseProject: model.canChooseProject
        )
        .equatable()
    }
}

private struct ProjectPickerRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    let path: String
    let status: ProjectStatus
    let canBuild: Bool
}

private struct ProjectPickerContent: View, Equatable {
    let model: DashboardViewModel
    let mode: ProjectPickerMode
    let allProjects: [ProjectPickerRow]
    let canChooseProject: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.mode == rhs.mode
            && lhs.allProjects == rhs.allProjects && lhs.canChooseProject == rhs.canChooseProject
    }

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlightedProjectID: UUID?
    @FocusState private var isSearchFocused: Bool

    private var filteredProjects: [ProjectPickerRow] {
        guard !query.isEmpty else { return allProjects }
        return allProjects.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query)
        }
    }


    var body: some View {
        let projects = filteredProjects
        let highlightedProject = projects.first { $0.id == highlightedProjectID }
        let canConfirm = canChooseProject && highlightedProject.map {
            mode == .switchProject || $0.canBuild
        } == true

        VStack(alignment: .leading, spacing: 16) {
            Text(mode == .build ? "Quick Build" : "Switch Project")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            TextField("Search project names or paths", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .accessibilityLabel("Search projects")
                .accessibilityHint("Filter by project name or path. Use Up and Down to select a result, then Return to confirm.")
                .onSubmit { confirm(build: mode == .build, projects: projects) }
                .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                    moveHighlight(offset: press.key == .upArrow ? -1 : 1, projects: projects)
                    return .handled
                }

            ScrollViewReader { proxy in
                List(selection: $highlightedProjectID) {
                    ForEach(projects) { project in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.name)
                                    .font(.headline)
                                Text(project.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .help(project.path)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 4) {
                                StatusBadgeView(status: project.status)
                                if mode == .build && !project.canBuild {
                                    Text("Build unavailable")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .tag(project.id)
                        .id(project.id)
                        .accessibilityElement(children: .combine)
                    }
                }
                .listStyle(.inset)
                .accessibilityLabel("Matching projects")
                .overlay {
                    if projects.isEmpty {
                        ContentUnavailableView {
                            Label(allProjects.isEmpty ? "No Projects" : "No Matching Projects",
                                  systemImage: "folder")
                        } description: {
                            Text(allProjects.isEmpty
                                 ? "Open an Xcode project or workspace to get started."
                                 : "Try another project name or path.")
                        }
                    }
                }
                .onChange(of: highlightedProjectID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            .frame(height: 300)

            if mode == .build {
                Text("Build uses the project's configured scheme, configuration, and destination.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if mode == .build {
                    Button("Switch Project") { confirm(build: false, projects: projects) }
                        .disabled(!canChooseProject || highlightedProject == nil)
                }
                Button(mode == .build ? "Build" : "Switch") {
                    confirm(build: mode == .build, projects: projects)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
            }
        }
        .padding(24)
        .frame(width: 620)
        .onAppear {
            highlightedProjectID = projects.first?.id
            isSearchFocused = true
        }
        .onChange(of: query) { _, _ in
            highlightedProjectID = projects.first?.id
        }
        .onChange(of: projects.map(\.id)) { _, ids in
            if highlightedProjectID.map({ ids.contains($0) }) != true {
                highlightedProjectID = ids.first
            }
        }
    }

    private func moveHighlight(offset: Int, projects: [ProjectPickerRow]) {
        guard !projects.isEmpty else {
            highlightedProjectID = nil
            return
        }
        guard let index = projects.firstIndex(where: { $0.id == highlightedProjectID }) else {
            highlightedProjectID = projects.first?.id
            return
        }
        let nextIndex = min(max(index + offset, 0), projects.count - 1)
        highlightedProjectID = projects[nextIndex].id
    }

    private func confirm(build: Bool, projects: [ProjectPickerRow]) {
        guard let highlightedProjectID,
              projects.contains(where: { $0.id == highlightedProjectID }) else { return }
        _ = model.chooseProject(highlightedProjectID, build: build)
    }
}
