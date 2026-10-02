import SwiftUI

struct ProjectImportPickerView: View {
    let selection: ProjectImportSelection
    let onChoose: (URL) -> Void
    let onCancel: () -> Void

    @State private var selectedURL: URL?
    @FocusState private var isListFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a Project or Workspace")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            Text("This folder contains multiple Xcode projects or workspaces. Select the one you want to import.")
                .foregroundStyle(.secondary)

            List(selection: $selectedURL) {
                ForEach(selection.candidates, id: \.self) { candidate in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(candidate.deletingPathExtension().lastPathComponent)
                                .font(.headline)
                            Spacer()
                            Text(candidate.pathExtension == "xcworkspace" ? "Workspace" : "Project")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(candidate.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(candidate.path)
                    }
                    .padding(.vertical, 4)
                    .tag(candidate)
                    .accessibilityElement(children: .combine)
                }
            }
            .listStyle(.inset)
            .frame(height: 300)
            .focused($isListFocused)
            .accessibilityLabel("Projects and workspaces in the selected folder")
            .accessibilityHint("Use Up and Down to select a project, then Return to import it.")

            Label {
                Text("Only import projects you trust. Project discovery and builds can execute scripts included in the project.")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import Selected") {
                    guard let selectedURL, selection.candidates.contains(selectedURL) else { return }
                    onChoose(selectedURL)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedURL.map { !selection.candidates.contains($0) } ?? true)
            }
        }
        .padding(24)
        .frame(width: 620)
        .onAppear { isListFocused = true }
    }
}
