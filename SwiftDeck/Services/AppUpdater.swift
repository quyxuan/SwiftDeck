import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var status = "Updates are delivered through GitHub Releases."
    @Published private(set) var installationIsDeferred = false

    var installationBlockReason: () -> String? = { nil }
    var willRequestRelaunch: () -> Void = {}
    private var controller: SPUStandardUpdaterController!
    private var deferredInstallation: (() -> Void)?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
        )
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloadsUpdates)
        updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastCheckDate)
        do {
            try updater.start()
        } catch {
            status = "Unable to start updates: \(error.localizedDescription)"
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        status = "Checking for updates…"
        controller.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticDownloads(_ enabled: Bool) {
        controller.updater.automaticallyDownloadsUpdates = enabled
    }

    func resumeInstallation() {
        guard let install = deferredInstallation else { return }
        if let reason = blockReason {
            status = reason
            return
        }
        deferredInstallation = nil
        installationIsDeferred = false
        install()
    }

    private var blockReason: String? {
        if let reason = installationBlockReason() { return reason }
        // Other processes do not share our operation registry. Never replace
        // their running bundle without the user first closing those instances.
        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        if NSWorkspace.shared.runningApplications.contains(where: {
               $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
               $0.bundleURL?.resolvingSymlinksInPath() == bundleURL
           }) {
            return "Close other SwiftDeck instances using this app before installing the update."
        }
        return nil
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = "Version \(item.displayVersionString) is available."
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        status = "No compatible newer version is available."
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        status = error.localizedDescription
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard let reason = blockReason else { return false }
        deferredInstallation = installHandler
        installationIsDeferred = true
        status = reason
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        willRequestRelaunch()
    }
}
