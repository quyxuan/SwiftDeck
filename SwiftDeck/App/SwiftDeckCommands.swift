import SwiftUI

struct SwiftDeckCommands: Commands {
    @ObservedObject var shortcuts: ShortcutStore
    @FocusedObject private var model: DashboardViewModel?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(ShortcutAction.openProject.title) { model?.addProject() }
                .keyboardShortcut(shortcuts[.openProject].keyboardShortcut)
                .disabled(model == nil || model?.isImporting == true)
        }
        CommandMenu("Project") {
            Button(ShortcutAction.switchProject.title) { model?.showProjectPicker(.switchProject) }
                .keyboardShortcut(shortcuts[.switchProject].keyboardShortcut)
                .disabled(model?.canChooseProject != true)
            Button(ShortcutAction.quickBuild.title) { model?.showProjectPicker(.build) }
                .keyboardShortcut(shortcuts[.quickBuild].keyboardShortcut)
                .disabled(model?.canChooseProject != true)
            Divider()
            ForEach(ShortcutAction.projectSelections.indices, id: \.self) { index in
                let action = ShortcutAction.projectSelections[index]
                Button(action.title) { model?.selectProject(at: index) }
                    .keyboardShortcut(shortcuts[action].keyboardShortcut)
                    .disabled(model?.canChooseProject != true || index >= (model?.projects.count ?? 0))
            }
            Button(ShortcutAction.previousProject.title) { model?.selectAdjacentProject(offset: -1) }
                .keyboardShortcut(shortcuts[.previousProject].keyboardShortcut)
                .disabled(model?.canChooseProject != true || model?.projects.isEmpty != false)
            Button(ShortcutAction.nextProject.title) { model?.selectAdjacentProject(offset: 1) }
                .keyboardShortcut(shortcuts[.nextProject].keyboardShortcut)
                .disabled(model?.canChooseProject != true || model?.projects.isEmpty != false)
            Divider()
            Button(ShortcutAction.build.title) { model?.build() }
                .keyboardShortcut(shortcuts[.build].keyboardShortcut)
                .disabled(model?.canBuild != true)
            Button(ShortcutAction.run.title) { model?.run() }
                .keyboardShortcut(shortcuts[.run].keyboardShortcut)
                .disabled(model?.canRun != true)
            Button(ShortcutAction.stop.title) { model?.stop() }
                .keyboardShortcut(shortcuts[.stop].keyboardShortcut)
                .disabled(model?.canStop != true)
            Divider()
            Button(ShortcutAction.clean.title) { model?.clean() }
                .keyboardShortcut(shortcuts[.clean].keyboardShortcut)
                .disabled(model?.canClean != true)
        }
        SidebarCommands()
    }
}
