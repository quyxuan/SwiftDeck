import AppKit

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    // Keep ownership even if SwiftUI releases a scene while cleanup is pending.
    private var models: [ObjectIdentifier: DashboardViewModel] = [:]
    private var windowDelegates: [ObjectIdentifier: WindowCloseDelegate] = [:]
    private var isTerminating = false
    var isUpdateRelaunch = false

    var updateInstallationBlockReason: String? {
        models.values.contains { $0.hasActiveOperations || $0.isChangingEmbeddedSimulator }
            ? "Finish or stop active builds, runs and device operations before installing the update."
            : nil
    }

    func register(_ model: DashboardViewModel) {
        models[ObjectIdentifier(model)] = model
    }

    func register(_ model: DashboardViewModel, window: NSWindow) {
        register(model)
        let id = ObjectIdentifier(model)
        if let delegate = windowDelegates[id], window.delegate === delegate { return }
        let delegate = WindowCloseDelegate(model: model, lifecycle: self, forwarding: window.delegate)
        windowDelegates[id] = delegate
        window.delegate = delegate
    }

    @discardableResult
    func close(_ model: DashboardViewModel) async -> Bool {
        guard await model.shutdown() else { return false }
        let id = ObjectIdentifier(model)
        models.removeValue(forKey: id)
        windowDelegates.removeValue(forKey: id)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isUpdateRelaunch, updateInstallationBlockReason != nil {
            isUpdateRelaunch = false
            return .terminateCancel
        }
        guard !isTerminating else { return .terminateLater }
        let activeModels = Array(models.values)
        guard !activeModels.isEmpty else { return .terminateNow }
        isTerminating = true
        Task {
            let succeeded = await withTaskGroup(of: Bool.self) { group in
                for model in activeModels {
                    group.addTask { await model.shutdown() }
                }
                var succeeded = true
                for await result in group { succeeded = result && succeeded }
                return succeeded
            }
            if !succeeded {
                for model in activeModels { model.resumeAfterCancelledShutdown() }
                isTerminating = false
            }
            sender.reply(toApplicationShouldTerminate: succeeded)
        }
        return .terminateLater
    }
}

/// Intercepts only the close decision; SwiftUI's delegate continues receiving
/// every other optional selector and the final close notification.
@MainActor
private final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    private let model: DashboardViewModel
    private weak var lifecycle: AppLifecycle?
    // Objective-C's forwarding hooks are nonisolated. AppKit accesses window
    // delegates on the main thread, as it does the forwarded SwiftUI delegate.
    nonisolated(unsafe) private weak var forwardedDelegate: (any NSWindowDelegate)?
    private var isClosing = false

    init(model: DashboardViewModel, lifecycle: AppLifecycle, forwarding delegate: (any NSWindowDelegate)?) {
        self.model = model
        self.lifecycle = lifecycle
        forwardedDelegate = delegate
    }

    override nonisolated func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || forwardedDelegate?.responds(to: selector) == true
    }

    override nonisolated func forwardingTarget(for selector: Selector!) -> Any? {
        if forwardedDelegate?.responds(to: selector) == true { return forwardedDelegate }
        return super.forwardingTarget(for: selector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isClosing, let lifecycle else { return false }
        guard forwardedDelegate?.windowShouldClose?(sender) != false else { return false }
        isClosing = true
        Task { [self, sender] in
            if await lifecycle.close(model) {
                // The original delegate already approved this request. close()
                // avoids repeating windowShouldClose while preserving willClose.
                sender.close()
            } else {
                isClosing = false
            }
        }
        return false
    }
}
