import SwiftUI

@main
struct SwiftDeckApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @StateObject private var preferences = AppPreferences.shared
    @StateObject private var shortcuts = ShortcutStore()
    @StateObject private var updater = AppUpdater()
    @StateObject private var workspaceStore = WorkspaceStore(defaults: .standard)

    var body: some Scene {
        WindowGroup {
            DashboardScene(lifecycle: lifecycle, workspaceStore: workspaceStore)
                .preferredColorScheme(preferences.appearance.colorScheme)
                .onAppear {
                    updater.installationBlockReason = { [weak lifecycle] in
                        lifecycle?.updateInstallationBlockReason
                    }
                    updater.willRequestRelaunch = { [weak lifecycle] in
                        lifecycle?.isUpdateRelaunch = true
                    }
                }
        }
        .defaultSize(width: 1120, height: 740)
        .windowResizability(.contentMinSize)
        .commands {
            SwiftDeckCommands(shortcuts: shortcuts)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        Settings {
            SettingsView(preferences: preferences, shortcuts: shortcuts, updater: updater)
        }
    }
}

private struct DashboardScene: View {
    let lifecycle: AppLifecycle
    @StateObject private var model: DashboardViewModel

    init(lifecycle: AppLifecycle, workspaceStore: WorkspaceStore) {
        self.lifecycle = lifecycle
        _model = StateObject(wrappedValue: DashboardViewModel(workspaceStore: workspaceStore))
    }

    var body: some View {
        DashboardView(model: model)
            .focusedSceneObject(model)
            .onAppear { lifecycle.register(model) }
            .background(WindowRegistration(model: model, lifecycle: lifecycle))
    }
}

private struct WindowRegistration: NSViewRepresentable {
    let model: DashboardViewModel
    let lifecycle: AppLifecycle

    func makeNSView(context: Context) -> WindowRegistrationView {
        let view = WindowRegistrationView()
        view.register = { window in lifecycle.register(model, window: window) }
        return view
    }

    func updateNSView(_ view: WindowRegistrationView, context: Context) {
        view.register = { window in lifecycle.register(model, window: window) }
        if let window = view.window { view.register?(window) }
    }
}

private final class WindowRegistrationView: NSView {
    var register: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { register?(window) }
    }
}
