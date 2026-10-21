import AppKit
import Foundation
import Testing
@testable import SwiftDeck

@Suite("Dashboard state and real-service operation ownership")
@MainActor
struct DashboardViewModelTests {
    @Test func emptyDashboardHasNoPhantomSelectionOrActions() {
        let model = DashboardViewModel(
            buildService: ControlledBuildService(), simulatorService: ControlledSimulatorService(),
            selectedProjectID: UUID()
        )
        #expect(model.projects.isEmpty && model.simulators.isEmpty)
        #expect(model.selectedProjectID == nil)
        #expect(!model.canBuild && !model.canRun && !model.canStop && !model.canClean)
        #expect(!model.canRemove && !model.canUseTools && !model.hasActiveOperations)
        model.build()
        model.run()
        model.clean()
        model.stop()
        model.removeProject()
        model.setConfiguration("Unknown")
        model.setScheme("Unknown")
        model.setSimulator(UUID())
        #expect(model.projects.isEmpty)
    }

    @Test func updateRelaunchDoesNotCancelWorkInAnUnselectedProject() async throws {
        let build = ControlledBuildService()
        defer { build.releaseAll() }
        let model = makeModel([project("Building"), project("Selected")], service: build)
        let lifecycle = AppLifecycle()
        lifecycle.register(model)
        model.build()
        try await waitUntil { build.requests.count == 1 }
        model.selectProject(at: 1)

        #expect(lifecycle.updateInstallationBlockReason != nil)
        lifecycle.isUpdateRelaunch = true
        #expect(lifecycle.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(model.hasActiveOperations)
        #expect(!lifecycle.isUpdateRelaunch)

        model.selectProject(at: 0)
        model.stop()
        build.releaseAll()
        try await waitUntil { !model.hasActiveOperations }
        #expect(lifecycle.updateInstallationBlockReason == nil)
    }

    @Test func indexedNavigationUsesSidebarOrderAndIgnoresInvalidIndices() {
        let apps = [project("Zebra"), project("Alpha"), project("Middle")]
        let model = makeModel(apps)
        model.selectProject(at: 1)
        #expect(model.selectedProjectID == apps[1].id)
        model.selectProject(at: -1)
        model.selectProject(at: apps.count)
        #expect(model.selectedProjectID == apps[1].id)
        model.selectProject(at: 2)
        #expect(model.selectedProjectID == apps[2].id)
        model.selectProject(at: 0)
        #expect(model.selectedProjectID == apps[0].id)
    }

    @Test func adjacentNavigationWrapsAndRecoversMissingSelection() {
        let apps = [project("First"), project("Middle"), project("Last")]
        let model = makeModel(apps)
        model.selectAdjacentProject(offset: -1)
        #expect(model.selectedProjectID == apps[2].id)
        model.selectAdjacentProject(offset: 1)
        #expect(model.selectedProjectID == apps[0].id)
        model.selectAdjacentProject(offset: 1)
        #expect(model.selectedProjectID == apps[1].id)
        model.selectProject(nil)
        model.selectAdjacentProject(offset: 1)
        #expect(model.selectedProjectID == apps[0].id)
        model.selectProject(nil)
        model.selectAdjacentProject(offset: -1)
        #expect(model.selectedProjectID == apps[2].id)
        model.selectAdjacentProject(offset: 0)
        #expect(model.selectedProjectID == apps[2].id)

        let single = makeModel([apps[0]])
        single.selectAdjacentProject(offset: -1)
        single.selectAdjacentProject(offset: 1)
        #expect(single.selectedProjectID == apps[0].id)
    }

    @Test func emptyPickerAndStaleChoicesNeverStartWorkOrChangeSelection() {
        let build = ControlledBuildService()
        let empty = makeModel([], service: build)
        empty.showProjectPicker(.build)
        empty.selectProject(at: 0)
        empty.selectAdjacentProject(offset: -1)
        #expect(!empty.chooseProject(UUID(), build: true))
        #expect(empty.selectedProjectID == nil && !empty.hasActiveOperations)
        #expect(empty.projectPickerMode == .build)

        let apps = [project("First"), project("Removed")]
        let model = makeModel(apps, service: build, selectedID: apps[1].id)
        model.removeProject()
        model.showProjectPicker(.switchProject)
        #expect(!model.chooseProject(apps[1].id, build: false))
        #expect(!model.chooseProject(apps[1].id, build: true))
        #expect(model.selectedProjectID == apps[0].id && !model.hasActiveOperations)
        #expect(model.projectPickerMode == .switchProject)
        #expect(build.requests.isEmpty)
    }

    @Test func quickBuildRejectsBusyProjectButSwitchCanSelectIt() async throws {
        let build = ControlledBuildService()
        defer { build.releaseAll() }
        let apps = [project("Busy"), project("Other")]
        let model = makeModel(apps, service: build)
        model.build()
        try await waitUntil { build.requests.count == 1 }
        model.selectAdjacentProject(offset: 1)
        model.showProjectPicker(.build)
        #expect(!model.canBuildProject(apps[0].id))
        #expect(!model.chooseProject(apps[0].id, build: true))
        #expect(model.selectedProjectID == apps[1].id && model.projectPickerMode == .build)
        #expect(model.projects[0].status == .building)
        #expect(model.chooseProject(apps[0].id, build: false))
        #expect(model.selectedProjectID == apps[0].id && model.projectPickerMode == nil)
        #expect(model.canStop && !model.isStopping)
        build.complete(0)
        try await waitUntil { !model.hasActiveOperations }
        #expect(build.requests.count == 1)
        #expect(model.selectedProject?.status == .idle)
    }

    @Test func quickBuildRejectsInvalidSettingsWithoutChangingSelection() {
        var invalid = project("Invalid")
        invalid.scheme = "Missing"
        var invalidConfiguration = project("Invalid Configuration")
        invalidConfiguration.configuration = "Missing"
        let valid = project("Valid")
        let build = ControlledBuildService()
        let model = makeModel([valid, invalid, invalidConfiguration], service: build)
        model.showProjectPicker(.build)
        for app in [invalid, invalidConfiguration] {
            #expect(!model.canBuildProject(app.id))
            #expect(!model.chooseProject(app.id, build: true))
            #expect(model.selectedProjectID == valid.id)
        }
        #expect(model.projectPickerMode == .build && !model.hasActiveOperations)
        #expect(build.requests.isEmpty)
    }

    @Test func quickBuildCapturesChosenProjectBeforeSelectionAndSettingsChange() async throws {
        let build = ControlledBuildService()
        defer { build.releaseAll() }
        let original = simulator("Original")
        let replacement = simulator("Replacement")
        var chosen = project("Chosen", destination: original.id)
        chosen.scheme = "AppTests"
        chosen.configuration = "Review"
        let other = project("Other")
        let model = makeModel([other, chosen], service: build,
                              simulatorService: ControlledSimulatorService([original, replacement]))
        await model.refreshSimulators()
        model.showProjectPicker(.build)
        #expect(model.chooseProject(chosen.id, build: true))
        #expect(model.selectedProjectID == chosen.id && model.projectPickerMode == nil)
        model.setScheme("App")
        model.setConfiguration("Debug")
        model.setSimulator(replacement.id)
        model.selectProject(at: 0)
        try await waitUntil { build.requests.count == 1 }
        let context = build.requests[0]
        #expect(context.projectID == chosen.id && context.projectPath == chosen.path)
        #expect(context.scheme == "AppTests" && context.configuration == "Review")
        #expect(context.simulatorID == original.id)
        build.output(0, "/Chosen/App.swift:3: error: chosen diagnostic")
        build.complete(0, error: ServiceFailure())
        try await waitUntil { !model.hasActiveOperations }
        #expect(model.selectedProjectID == other.id && model.projects[0].status == .idle)
        #expect(model.logStore(for: model.projects[0].id).entries.isEmpty && model.projects[1].status == .failed)
        #expect(model.projects[1].issues.first?.file == "/Chosen/App.swift")
    }

    @Test func refreshRepairsDestinationsAndPreservesValidSelection() async {
        let unavailable = simulator("Unavailable", status: .unavailable)
        let available = simulator("Available")
        let booted = simulator("Booted", status: .booted)
        let apps = [project("Missing", destination: UUID()), project("Unavailable", destination: unavailable.id),
                    project("Unset"), project("Valid", destination: booted.id)]
        let model = makeModel(apps, simulatorService: ControlledSimulatorService([unavailable, available, booted]), selectedID: apps[3].id)
        await model.refreshSimulators()
        #expect(model.selectedProjectID == apps[3].id)
        #expect(model.projects.map(\.selectedSimulatorID) == [available.id, available.id, available.id, booted.id])
    }

    @Test func refreshFailurePreservesInventoryAndExposesDismissibleError() async {
        let phone = simulator("Phone")
        let service = ControlledSimulatorService([phone])
        let model = makeModel([project("App")], simulatorService: service)
        await model.refreshSimulators()
        service.inventoryError = ServiceFailure()
        await model.refreshSimulators()
        #expect(model.simulators.map(\.id) == [phone.id])
        #expect(model.errorMessage != nil && !model.isRefreshing)
        model.dismissError()
        #expect(model.errorMessage == nil)
    }

    @Test func screenshotShortcutTargetsBootedProjectDestinationOnly() async throws {
        let phone = simulator("Phone", status: .booted)
        let ipad = simulator("iPad", status: .available)
        let service = ControlledSimulatorService([phone, ipad])
        let model = makeModel([project("App", destination: phone.id)], simulatorService: service)
        await model.refreshSimulators()
        #expect(model.screenshotSimulatorID == phone.id)
        model.setSimulator(ipad.id)
        #expect(model.screenshotSimulatorID == nil)
        service.inventory[1].status = .booted
        await model.refreshSimulators()
        #expect(model.screenshotSimulatorID == ipad.id)
        model.takeScreenshot()
        #expect(model.screenshotFeedback?.id == nil)
        try await waitUntil { service.screenshotDestinations.count == 1 }
        try await waitUntil { !model.hasActiveOperations }
        let firstFeedback = try #require(model.screenshotFeedback)
        #expect(firstFeedback.message == "Screenshot saved")
        model.takeScreenshot()
        try await waitUntil { service.screenshotDestinations.count == 2 }
        try await waitUntil { !model.hasActiveOperations }
        let secondFeedback = try #require(model.screenshotFeedback)
        #expect(secondFeedback.id != firstFeedback.id)
        model.dismissScreenshotFeedback(firstFeedback.id)
        #expect(model.screenshotFeedback?.id == secondFeedback.id)
        let shots = service.screenshotDestinations
        #expect(shots.map(\.0) == [ipad.id, ipad.id])
        #expect(shots[0].1 != shots[1].1)
        #expect(shots.allSatisfy {
            $0.1.deletingLastPathComponent() == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
                && $0.1.pathExtension == "png"
        })
        model.selectProject(nil)
        model.takeScreenshot()
        #expect(model.screenshotSimulatorID == nil && service.screenshotDestinations.count == 2)
    }

    @Test func copyScreenshotPutsPNGOnClipboardAndRemovesTemporaryCapture() async throws {
        let pasteboard = NSPasteboard.general
        let previous: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item in
            let saved = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { _ = saved.setData(data, forType: type) }
            }
            return saved
        } ?? []
        defer {
            pasteboard.clearContents()
            if !previous.isEmpty {
                let items: [any NSPasteboardWriting] = previous.map { $0 }
                _ = pasteboard.writeObjects(items)
            }
        }
        let phone = simulator("Phone", status: .booted)
        let service = ControlledSimulatorService([phone])
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        service.screenshotData = png
        let model = makeModel([project("App", destination: phone.id)], simulatorService: service)
        await model.refreshSimulators()

        model.copyScreenshot()
        try await waitUntil { !model.hasActiveOperations }
        let feedback = try #require(model.screenshotFeedback)
        #expect(feedback.message == "Screenshot copied to clipboard")
        let capture = try #require(service.screenshotDestinations.first)
        #expect(capture.0 == phone.id)
        #expect(capture.1.deletingLastPathComponent() == FileManager.default.temporaryDirectory)
        #expect(!FileManager.default.fileExists(atPath: capture.1.path))
        #expect(pasteboard.data(forType: .png) == png)
        service.screenshotData = nil
        model.copyScreenshot()
        try await waitUntil { !model.hasActiveOperations }
        #expect(model.screenshotFeedback?.id == nil)
        #expect(model.errorMessage?.contains("Copying Screenshot failed") == true)
    }

    @Test func unavailableInventoryAllowsBuildButNotRun() async throws {
        let service = ControlledBuildService()
        defer { service.releaseAll() }
        let unavailable = simulator("Missing Runtime", status: .unavailable)
        let model = makeModel([project("App", destination: unavailable.id)], service: service,
                              simulatorService: ControlledSimulatorService([unavailable]))
        await model.refreshSimulators()
        #expect(model.selectedProject?.selectedSimulatorID == nil)
        #expect(model.canBuild && !model.canRun)
        model.run()
        #expect(model.selectedProject?.status == .idle)
        model.build()
        try await waitUntil { service.requests.count == 1 }
        #expect(service.requests.first?.simulatorID == nil)
        service.complete(0)
        await model.shutdown()
    }

    @Test func importDeduplicatesCanonicalAndSymlinkPaths() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Trusted.xcodeproj")
        let alias = directory.appendingPathComponent("Alias.xcodeproj")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        let service = ControlledBuildService()
        var imported = project("Trusted")
        imported.path = url.path
        service.discoveredProject = imported
        let model = makeModel([], service: service)
        await model.refreshSimulators()
        await model.importProject(at: url)
        model.selectProject(nil)
        await model.importProject(at: alias)
        #expect(model.projects.map(\.id) == [imported.id])
        #expect(model.selectedProjectID == imported.id)
        #expect(service.discoveryURLs == [url.resolvingSymlinksInPath()])
        #expect(model.selectedProject?.selectedSimulatorID == model.simulators.first?.id)
    }

    @Test func failedImportDoesNotAddProjectOrLoseSelection() async {
        let app = project("Existing")
        let service = ControlledBuildService()
        service.discoveryError = ServiceFailure()
        let model = makeModel([app], service: service)
        await model.importProject(at: URL(fileURLWithPath: "/Test/Invalid.xcodeproj"))
        #expect(model.projects.map(\.id) == [app.id])
        #expect(model.selectedProjectID == app.id)
        #expect(model.errorMessage != nil && !model.isImporting)
    }

    @Test func cancelledImportRejectsLateDiscovery() async throws {
        let service = ControlledBuildService()
        defer { service.releaseAll() }
        service.holdDiscovery = true
        let model = makeModel([], service: service)
        let request = Task { await model.importProject(at: URL(fileURLWithPath: "/Test/Late.xcodeproj")) }
        try await waitUntil { service.discoveryPending != nil }
        #expect(model.isImporting)
        request.cancel()
        service.finishDiscovery(project("Late"))
        await request.value
        #expect(model.projects.isEmpty && !model.isImporting)
        #expect(model.errorMessage == nil)
    }

    @Test(arguments: [0, 1, 2])
    func removalSelectsAdjacentProject(removedIndex: Int) {
        let apps = [project("First"), project("Middle"), project("Last")]
        let model = makeModel(apps, selectedID: apps[removedIndex].id)
        let remaining = apps.enumerated().filter { $0.offset != removedIndex }.map(\.element)
        model.removeProject()
        #expect(model.projects.map(\.id) == remaining.map(\.id))
        #expect(model.selectedProjectID == remaining[min(removedIndex, remaining.count - 1)].id)
    }

    @Test func editsValidateAndStayWithSelectedProject() async throws {
        let first = simulator("First")
        let second = simulator("Second")
        let unavailable = simulator("Unavailable", status: .unavailable)
        let apps = [project("One", destination: first.id), project("Two", destination: first.id)]
        let model = makeModel(apps, simulatorService: ControlledSimulatorService([first, second, unavailable]))
        await model.refreshSimulators()
        model.selectProject(apps[1].id)
        model.setScheme("AppTests")
        model.setConfiguration("Review")
        model.setSimulator(second.id)
        model.setScheme("Invalid")
        model.setConfiguration("Invalid")
        model.setSimulator(unavailable.id)
        let selected = try #require(model.selectedProject)
        #expect(selected.scheme == "AppTests" && selected.configuration == "Review")
        #expect(selected.selectedSimulatorID == second.id)
        #expect(model.projects[0] == apps[0])
        model.selectProject(UUID())
        #expect(model.selectedProjectID == nil && !model.canBuild)
    }

    @Test func rerunWaitsForCancelledBuildAndStopDiscardsQueuedRun() async throws {
        let build = ControlledBuildService()
        let phone = simulator("Phone")
        let sim = ControlledSimulatorService([phone])
        defer { build.releaseAll(); sim.releaseAll() }
        let model = makeModel([project("App", destination: phone.id)], service: build, simulatorService: sim)
        await model.refreshSimulators()
        model.build()
        try await waitUntil { build.requests.count == 1 }
        #expect(model.canRun)
        model.run()
        #expect(model.isStopping && model.canStop)
        #expect(build.requests.count == 1)
        model.stop()
        build.complete(0, error: CancellationError())
        try await waitUntil { !model.hasActiveOperations }
        #expect(build.requests.count == 1 && sim.requests.isEmpty)

        model.build()
        try await waitUntil { build.requests.count == 2 }
        model.run()
        build.complete(1, error: CancellationError())
        try await waitUntil { build.requests.count == 3 }
        #expect(build.requests[2].simulatorID == phone.id)
        build.complete(2)
        try await waitUntil { sim.requests.count == 1 }
        sim.complete(0)
        try await waitUntil { !model.hasActiveOperations }
    }

    @Test func rerunRunningAppWaitsForDeviceCleanup() async throws {
        let build = ControlledBuildService()
        let phone = simulator("Phone")
        let sim = ControlledSimulatorService([phone])
        defer { build.releaseAll(); sim.releaseAll() }
        let model = makeModel([project("App", destination: phone.id)], service: build, simulatorService: sim)
        await model.refreshSimulators()
        model.run()
        try await waitUntil { build.requests.count == 1 }
        build.complete(0)
        try await waitUntil { sim.requests.count == 1 }
        sim.launch(0)
        #expect(model.canRun && model.canBuild)
        model.run()
        #expect(build.requests.count == 1)
        sim.complete(0, error: CancellationError())
        try await waitUntil { build.requests.count == 2 }
        build.complete(1)
        try await waitUntil { sim.requests.count == 2 }
        sim.launch(1)
        model.build()
        #expect(build.requests.count == 2)
        sim.complete(1, error: CancellationError())
        try await waitUntil { build.requests.count == 3 }
        build.complete(2)
        try await waitUntil { !model.hasActiveOperations }
        #expect(sim.requests.count == 2 && model.selectedProject?.status == .idle)
    }

    @Test func runAwaitsLaunchAndExitWithCapturedSettings() async throws {
        let build = ControlledBuildService()
        let original = simulator("Original")
        let replacement = simulator("Replacement")
        let sim = ControlledSimulatorService([original, replacement])
        defer { build.releaseAll(); sim.releaseAll() }
        let model = makeModel([project("App", destination: original.id)], service: build, simulatorService: sim)
        await model.refreshSimulators()
        model.setConfiguration("Review")
        model.setScheme("AppTests")
        model.run()
        model.setConfiguration("Debug")
        model.setScheme("App")
        model.setSimulator(replacement.id)
        try await waitUntil { build.requests.count == 1 }
        #expect(build.requests[0].configuration == "Review" && build.requests[0].scheme == "AppTests")
        build.complete(0)
        try await waitUntil { sim.requests.count == 1 }
        #expect(build.artifactRequests.first?.configuration == "Review")
        #expect(build.artifactRequests.first?.scheme == "AppTests")
        #expect(build.artifactRequests.first?.simulatorID == original.id)
        #expect(sim.requests[0] == original.id)
        #expect(model.selectedProject?.status == .building)
        sim.launch(0)
        #expect(model.selectedProject?.status == .running && model.canStop)
        #expect(model.simulators.first(where: { $0.id == original.id })?.status == .booted)
        #expect(model.simulators.first(where: { $0.id == replacement.id })?.status == .available)
        #expect(model.canBuild && !model.canClean)
        sim.complete(0)
        try await waitUntil { !model.hasActiveOperations }
        #expect(model.selectedProject?.status == .stopped && model.canBuild)
    }

    @Test func acceptingConflictResumesCapturedRunWithoutAnotherBuildAndKeepsLeases() async throws {
        let build = ControlledBuildService()
        let original = simulator("Original", status: .booted)
        let replacement = simulator("Replacement", status: .booted)
        let sim = ControlledSimulatorService([original, replacement])
        sim.conflicts[original.id] = conflict(on: original)
        defer { build.releaseAll(); sim.releaseAll() }
        let apps = [project("App", destination: original.id), project("Other", destination: replacement.id)]
        let model = makeModel(apps, service: build, simulatorService: sim)
        let otherWindow = makeModel([apps[0]], simulatorService: sim)
        await model.refreshSimulators()
        await otherWindow.refreshSimulators()
        model.setScheme("AppTests")
        model.setConfiguration("Review")
        model.run()
        try await waitUntil { build.requests.count == 1 }
        #expect(model.runningAppConfirmation == nil && sim.requests.isEmpty)
        build.complete(0)
        try await waitUntil { model.runningAppConfirmation != nil }
        let confirmation = try #require(model.runningAppConfirmation)
        #expect(confirmation.projectID == apps[0].id)
        #expect(model.canBuild && model.canStop)
        #expect(!otherWindow.canBuild && !otherWindow.canRun)
        #expect(!otherWindow.canSimulatorAction(.shutdown, on: original.id))
        #expect(otherWindow.canSimulatorAction(.shutdown, on: replacement.id))
        #expect(!sim.isReadyToLaunch(0))
        model.setScheme("App")
        model.setConfiguration("Debug")
        model.setSimulator(replacement.id)
        model.selectProject(apps[1].id)
        model.resolveRunningAppConflict(confirmation.id, stopAndRun: true)
        try await waitUntil { sim.isReadyToLaunch(0) }
        #expect(model.runningAppConfirmation == nil)
        #expect(build.requests.count == 1 && build.artifactRequests.count == 1)
        #expect(build.artifactRequests[0].scheme == "AppTests")
        #expect(build.artifactRequests[0].configuration == "Review")
        #expect(sim.requests == [original.id])
        sim.launch(0)
        #expect(model.projects[0].status == .running && model.projects[1].status == .idle)
        #expect(model.selectedProjectID == apps[1].id)
        #expect(!otherWindow.canBuild)
        sim.complete(0)
        try await waitUntil { !model.hasActiveOperations }
        #expect(otherWindow.canBuild && otherWindow.canRun)
        #expect(otherWindow.canSimulatorAction(.shutdown, on: original.id))
    }

    @Test func decliningConflictCannotLaunchAndStaleAnswerCannotAcceptNextRun() async throws {
        let build = ControlledBuildService()
        let phone = simulator("Phone")
        let sim = ControlledSimulatorService([phone])
        sim.conflicts[phone.id] = conflict(on: phone)
        defer { build.releaseAll(); sim.releaseAll() }
        let model = makeModel([project("App")], service: build, simulatorService: sim)
        await model.refreshSimulators()
        model.run()
        try await waitUntil { build.requests.count == 1 }
        build.complete(0)
        try await waitUntil { model.runningAppConfirmation != nil }
        let declined = try #require(model.runningAppConfirmation)
        model.resolveRunningAppConflict(declined.id, stopAndRun: false)
        try await waitUntil { !model.hasActiveOperations }
        #expect(model.selectedProject?.status == .stopped && model.canRun)
        #expect(model.runningAppConfirmation == nil && !sim.isReadyToLaunch(0))
        model.run()
        try await waitUntil { build.requests.count == 2 }
        build.complete(1)
        try await waitUntil { model.runningAppConfirmation != nil }
        let current = try #require(model.runningAppConfirmation)
        #expect(current.id != declined.id)
        model.resolveRunningAppConflict(declined.id, stopAndRun: true)
        #expect(model.runningAppConfirmation?.id == current.id)
        #expect(!sim.isReadyToLaunch(1) && model.selectedProject?.status == .building)
        model.resolveRunningAppConflict(current.id, stopAndRun: false)
        try await waitUntil { !model.hasActiveOperations }
        #expect(!sim.isReadyToLaunch(1) && model.selectedProject?.status == .stopped)
    }

    @Test(arguments: [false, true])
    func stoppingOrRemovingPendingConflictDrainsWithoutLaunch(removing: Bool) async throws {
        let build = ControlledBuildService()
        let phone = simulator("Phone", status: .booted)
        let sim = ControlledSimulatorService([phone])
        sim.conflicts[phone.id] = conflict(on: phone)
        defer { build.releaseAll(); sim.releaseAll() }
        let app = project("App")
        let model = makeModel([app], service: build, simulatorService: sim)
        await model.refreshSimulators()
        model.run()
        try await waitUntil { build.requests.count == 1 }
        build.complete(0)
        try await waitUntil { model.runningAppConfirmation != nil }
        let confirmation = try #require(model.runningAppConfirmation)
        if removing { model.removeProject() } else { model.stop() }
        #expect(model.runningAppConfirmation == nil)
        model.resolveRunningAppConflict(confirmation.id, stopAndRun: true)
        try await waitUntil { !model.hasActiveOperations }
        #expect(!sim.isReadyToLaunch(0))
        #expect(ProjectOperationRegistry.shared.isAvailable(app.id))
        #expect(model.canSimulatorAction(.shutdown, on: phone.id))
        if removing {
            #expect(model.projects.isEmpty && model.selectedProjectID == nil)
        } else {
            #expect(model.selectedProject?.status == .stopped && model.canRun)
        }
    }

    @Test(arguments: [false, true])
    func cancellingOneConflictDoesNotResolveAnotherProject(cancelQueued: Bool) async throws {
        let build = ControlledBuildService()
        let phones = [simulator("First"), simulator("Second")]
        let sim = ControlledSimulatorService(phones)
        for phone in phones { sim.conflicts[phone.id] = conflict(on: phone) }
        defer { build.releaseAll(); sim.releaseAll() }
        let apps = [project("First", destination: phones[0].id), project("Second", destination: phones[1].id)]
        let model = makeModel(apps, service: build, simulatorService: sim)
        await model.refreshSimulators()
        model.run()
        try await waitUntil { build.requests.count == 1 }
        build.complete(0)
        try await waitUntil { model.runningAppConfirmation != nil }
        let first = try #require(model.runningAppConfirmation)
        model.selectProject(apps[1].id)
        model.run()
        try await waitUntil { build.requests.count == 2 }
        build.complete(1)
        try await waitUntil { sim.conflictRequests.count == 2 }
        #expect(model.runningAppConfirmation?.id == first.id)
        let cancelled = cancelQueued ? 1 : 0
        let remaining = cancelQueued ? 0 : 1
        model.selectProject(apps[cancelled].id)
        model.stop()
        try await waitUntil { model.projects[cancelled].status == .stopped }
        let confirmation = try #require(model.runningAppConfirmation)
        #expect(confirmation.projectID == apps[remaining].id)
        if !cancelQueued {
            model.resolveRunningAppConflict(first.id, stopAndRun: true)
            #expect(model.runningAppConfirmation?.id == confirmation.id)
        }
        #expect(!sim.isReadyToLaunch(0) && !sim.isReadyToLaunch(1))
        model.resolveRunningAppConflict(confirmation.id, stopAndRun: true)
        try await waitUntil { sim.isReadyToLaunch(remaining) }
        #expect(!sim.isReadyToLaunch(cancelled))
        sim.launch(remaining)
        #expect(model.projects[remaining].status == .running)
        #expect(model.projects[cancelled].status == .stopped)
        sim.complete(remaining)
        try await waitUntil { !model.hasActiveOperations }
        #expect(model.runningAppConfirmation == nil && build.requests.count == 2)
    }

    @Test func shutdownDrainsVisibleAndQueuedConflictsWithoutAnswers() async throws {
        let build = ControlledBuildService()
        let phones = [simulator("First"), simulator("Second")]
        let sim = ControlledSimulatorService(phones)
        for phone in phones { sim.conflicts[phone.id] = conflict(on: phone) }
        defer { build.releaseAll(); sim.releaseAll() }
        let apps = [project("First", destination: phones[0].id), project("Second", destination: phones[1].id)]
        let model = makeModel(apps, service: build, simulatorService: sim)
        await model.refreshSimulators()
        for index in apps.indices {
            model.selectProject(apps[index].id)
            model.run()
            try await waitUntil { build.requests.count == index + 1 }
            build.complete(index)
            try await waitUntil { sim.conflictRequests.count == index + 1 }
        }
        let confirmation = try #require(model.runningAppConfirmation)
        var closed: Bool?
        let closing = Task { closed = await model.shutdown() }
        try await waitUntil { closed != nil }
        await closing.value
        #expect(closed == true && !model.hasActiveOperations)
        #expect(model.runningAppConfirmation == nil)
        model.resolveRunningAppConflict(confirmation.id, stopAndRun: true)
        #expect(!sim.isReadyToLaunch(0) && !sim.isReadyToLaunch(1))
        #expect(model.projects.allSatisfy { $0.status == .stopped })
        for index in apps.indices {
            #expect(ProjectOperationRegistry.shared.isAvailable(apps[index].id))
            #expect(SimulatorOperationRegistry.shared.canAcquire(.run, on: phones[index].id))
        }
    }

    @Test func deinitializingDashboardDrainsPendingConflictAndReleasesLeases() async throws {
        let build = ControlledBuildService()
        let phone = simulator("Phone")
        let sim = ControlledSimulatorService([phone])
        sim.conflicts[phone.id] = conflict(on: phone)
        defer { build.releaseAll(); sim.releaseAll() }
        let app = project("App")
        var model: DashboardViewModel? = makeModel([app], service: build, simulatorService: sim)
        weak let releasedModel = model
        await model?.refreshSimulators()
        model?.run()
        try await waitUntil { build.requests.count == 1 }
        build.complete(0)
        try await waitUntil { model?.runningAppConfirmation != nil }
        model = nil
        #expect(releasedModel == nil)
        try await waitUntil { ProjectOperationRegistry.shared.isAvailable(app.id) }
        #expect(SimulatorOperationRegistry.shared.canAcquire(.run, on: phone.id))
        #expect(!sim.isReadyToLaunch(0))
    }

    @Test func stopBlocksRestartUntilCancellationCleanupFinishes() async throws {
        let build = ControlledBuildService()
        let sim = ControlledSimulatorService([simulator("Phone")])
        defer { build.releaseAll(); sim.releaseAll() }
        let model = makeModel([project("App")], service: build, simulatorService: sim)
        await model.refreshSimulators()
        model.run()
        try await waitUntil { build.requests.count == 1 }
        build.complete(0)
        try await waitUntil { sim.requests.count == 1 }
        sim.launch(0)
        model.stop()
        #expect(model.isStopping && model.hasActiveOperations)
        #expect(!model.canBuild && !model.canRun && !model.canClean && !model.canStop)
        model.run()
        model.build()
        model.clean()
        sim.launch(0) // Late launch notifications cannot undo the stopping barrier.
        #expect(model.isStopping)
        #expect(build.requests.count == 1)
        sim.complete(0, error: CancellationError())
        try await waitUntil { !model.hasActiveOperations }
        #expect(model.selectedProject?.status == .stopped && model.canRun)
        model.build()
        try await waitUntil { build.requests.count == 2 }
        let issueCount = model.selectedProject?.issues.count
        build.output(0, "/Old.swift:9:2: error: stale diagnostic")
        #expect(model.selectedProject?.issues.count == issueCount)
        build.complete(1)
        try await waitUntil { !model.hasActiveOperations }
        #expect(model.selectedProject?.status == .idle)
    }

    @Test(arguments: [false, true])
    func stoppingBuildRejectsLateCompletionBeforeSimulatorEffects(failure: Bool) async throws {
        let build = ControlledBuildService()
        let sim = ControlledSimulatorService([simulator("Phone")])
        defer { build.releaseAll(); sim.releaseAll() }
        let model = makeModel([project("App")], service: build, simulatorService: sim)
        await model.refreshSimulators()
        model.run()
        try await waitUntil { build.requests.count == 1 }
        model.stop()
        build.complete(0, error: failure ? ServiceFailure() : nil)
        try await waitUntil { !model.hasActiveOperations }
        #expect(sim.requests.isEmpty)
        #expect(build.artifactRequests.isEmpty)
        #expect(model.selectedProject?.status == .stopped)
    }

    @Test func buildSucceedsWithoutRunArtifactDiscovery() async throws {
        let build = ControlledBuildService()
        build.artifactError = ServiceFailure()
        defer { build.releaseAll() }
        let model = makeModel([project("Library")], service: build)
        model.build()
        try await waitUntil { build.requests.count == 1 }
        build.complete(0)
        try await waitUntil { !model.hasActiveOperations }
        #expect(model.selectedProject?.status == .idle && model.canBuild)
        #expect(build.artifactRequests.isEmpty)
    }

    @Test(arguments: [false, true])
    func runBuildOrArtifactFailureNeverRequestsConflictOrLaunch(artifactFailure: Bool) async throws {
        let build = ControlledBuildService()
        if artifactFailure { build.artifactError = ServiceFailure() }
        let phone = simulator("Phone")
        let sim = ControlledSimulatorService([phone])
        sim.conflicts[phone.id] = conflict(on: phone)
        defer { build.releaseAll(); sim.releaseAll() }
        let model = makeModel([project("App")], service: build, simulatorService: sim)
        await model.refreshSimulators()
        model.run()
        try await waitUntil { build.requests.count == 1 }
        build.complete(0, error: artifactFailure ? nil : ServiceFailure())
        try await waitUntil { !model.hasActiveOperations }
        #expect(model.selectedProject?.status == .failed)
        #expect(model.logStore(for: model.selectedProjectID!).entries.last?.level == .error)
        #expect(sim.requests.isEmpty && model.canRun)
        #expect(sim.conflictRequests.isEmpty && model.runningAppConfirmation == nil)
        #expect(build.artifactRequests.count == (artifactFailure ? 1 : 0))
    }

    @Test(arguments: [false, true])
    func stoppingRunArtifactDiscoveryRejectsLateResults(failure: Bool) async throws {
        let build = ControlledBuildService()
        build.holdArtifactDiscovery = true
        let sim = ControlledSimulatorService([simulator("Phone")])
        defer { build.releaseAll(); sim.releaseAll() }
        let model = makeModel([project("App")], service: build, simulatorService: sim)
        await model.refreshSimulators()
        model.run()
        try await waitUntil { build.requests.count == 1 }
        build.complete(0)
        try await waitUntil { build.artifactPending != nil }
        model.stop()
        #expect(model.isStopping && !model.canBuild)
        build.finishArtifactDiscovery(error: failure ? ServiceFailure() : nil)
        try await waitUntil { !model.hasActiveOperations }
        #expect(sim.requests.isEmpty)
        #expect(model.selectedProject?.status == .stopped && model.canRun)
    }

    @Test func removalWaitsForCleanupAndDoesNotRedirectNewSelection() async throws {
        let build = ControlledBuildService()
        let sim = ControlledSimulatorService([simulator("Phone")])
        defer { build.releaseAll(); sim.releaseAll() }
        let apps = [project("Removed"), project("Other"), project("Selected")]
        let model = makeModel(apps, service: build, simulatorService: sim)
        await model.refreshSimulators()
        model.run()
        try await waitUntil { build.requests.count == 1 }
        build.complete(0)
        try await waitUntil { sim.requests.count == 1 }
        sim.launch(0)
        model.removeProject()
        #expect(model.projects.count == 3 && model.isStopping && !model.canRemove)
        model.selectProject(apps[2].id)
        sim.complete(0, error: CancellationError())
        try await waitUntil { !model.hasActiveOperations }
        #expect(model.projects.map(\.id) == [apps[1].id, apps[2].id])
        #expect(model.selectedProjectID == apps[2].id)
        #expect(model.logStore(for: apps[2].id).entries.isEmpty)
    }

    @Test func removingOnlyActiveProjectCannotResurrectIt() async throws {
        let service = ControlledBuildService()
        defer { service.releaseAll() }
        let model = makeModel([project("Only")], service: service)
        model.build()
        try await waitUntil { service.requests.count == 1 }
        model.removeProject()
        #expect(!model.projects.isEmpty)
        service.complete(0)
        try await waitUntil { model.projects.isEmpty }
        #expect(model.selectedProjectID == nil && !model.hasActiveOperations)
    }

    @Test func concurrentProjectsOwnTheirOutputAndCompletion() async throws {
        let service = ControlledBuildService()
        defer { service.releaseAll() }
        let apps = [project("First"), project("Second")]
        let model = makeModel(apps, service: service)
        model.build()
        try await waitUntil { service.requests.count == 1 }
        model.selectProject(apps[1].id)
        model.build()
        try await waitUntil { service.requests.count == 2 }
        service.output(0, "/First/App.swift:11:4: warning: first warning")
        service.output(1, "/Second/App.swift:22: error: second error")
        service.complete(1, error: ServiceFailure())
        service.complete(0)
        try await waitUntil { !model.hasActiveOperations }
        #expect(model.projects[0].status == .idle)
        #expect(model.projects[0].issues.first?.severity == .warning)
        #expect(model.projects[0].issues.first?.line == 11)
        #expect(model.projects[1].status == .failed)
        #expect(model.projects[1].issues.first?.file == "/Second/App.swift")
        #expect(model.selectedProjectID == apps[1].id)
    }

    @Test func cancellationFlushesBufferedOutputBeforeTerminalStatus() async throws {
        let service = ControlledBuildService()
        defer { service.releaseAll() }
        let app = project("App")
        let model = makeModel([app], service: service)
        model.build()
        try await waitUntil { service.requests.count == 1 }
        service.output(0, "before cancellation")
        model.stop()
        service.output(0, "/App.swift:7: error: final diagnostic")
        service.output(0, "last drained line")
        service.complete(0, error: CancellationError())
        try await waitUntil { !model.hasActiveOperations }
        let entries = model.logStore(for: app.id).entries
        #expect(Array(entries.suffix(4)).map(\.message) == [
            "before cancellation", "/App.swift:7: error: final diagnostic",
            "last drained line", "Operation stopped."
        ])
        #expect(model.selectedProject?.issues.first?.line == 7)
        #expect(model.selectedProject?.status == .stopped)
        service.output(0, "callback after completion")
        #expect(model.logStore(for: app.id).entries.last?.message == "Operation stopped.")
    }

    @Test func boundedLogSnapshotsKeepTheirOrderAcrossPageEviction() {
        var entries = BoundedEntries<Int>(limit: 257)
        for value in 0..<300 { entries.append(value) }
        let snapshot = entries
        for value in 300..<700 { entries.append(value) }
        #expect(Array(snapshot) == Array(43..<300))
        #expect(Array(entries) == Array(443..<700))
        #expect(entries[entries.index(entries.startIndex, offsetBy: 128)] == 571)
    }

    @Test func compilerDiagnosticsAndBoundedLogsPreserveRealLocations() async throws {
        let service = ControlledBuildService()
        defer { service.releaseAll() }
        let model = makeModel([project("App")], service: service)
        model.build()
        try await waitUntil { service.requests.count == 1 }
        for index in 0..<5_010 { service.output(0, "build output \(index)") }
        service.output(0, "/Source Folder/App.swift:42:9: error: missing expression")
        service.output(0, "Relative.swift:8: warning: deprecated API")
        service.output(0, "/Source/Other.swift:2:1: note: declared here")
        service.output(0, "error: unlocated linker error")
        service.complete(0, error: ServiceFailure())
        try await waitUntil { !model.hasActiveOperations }
        let app = try #require(model.selectedProject)
        #expect(model.logStore(for: app.id).entries.count == 5_000)
        #expect(model.logStore(for: app.id).entries.first?.message == "build output 15")
        #expect(app.issues.map(\.severity) == [.error, .warning, .note])
        #expect(app.issues.map(\.line) == [42, 8, 2])
        #expect(app.issues[0].file == "/Source Folder/App.swift")
        #expect(app.issues[1].file == "Relative.swift")
        #expect(app.status == .failed)
    }

    @Test func failedBuildDoesNotInventDiagnosticAndCleanAwaitsService() async throws {
        let service = ControlledBuildService()
        defer { service.releaseAll() }
        let model = makeModel([project("App")], service: service)
        model.build()
        try await waitUntil { service.requests.count == 1 }
        service.complete(0, error: ServiceFailure())
        try await waitUntil { !model.hasActiveOperations }
        #expect(model.selectedProject?.status == .failed)
        #expect(model.selectedProject?.issues.isEmpty == true)
        model.clean()
        try await waitUntil { service.requests.count == 2 }
        #expect(service.cleanRequests == [1])
        #expect(model.canBuild && !model.canClean && model.canStop)
        service.complete(1, error: ServiceFailure())
        try await waitUntil { !model.hasActiveOperations }
        #expect(model.selectedProject?.status == .failed)
        model.clean()
        try await waitUntil { service.requests.count == 3 }
        service.complete(2)
        try await waitUntil { !model.hasActiveOperations }
        #expect(model.selectedProject?.status == .idle)
    }

    @Test func simulatorLaunchFailureNeverReportsRunning() async throws {
        let build = ControlledBuildService()
        let sim = ControlledSimulatorService([simulator("Phone")])
        defer { build.releaseAll(); sim.releaseAll() }
        let model = makeModel([project("App")], service: build, simulatorService: sim)
        await model.refreshSimulators()
        model.run()
        try await waitUntil { build.requests.count == 1 }
        build.complete(0)
        try await waitUntil { sim.requests.count == 1 }
        sim.complete(0, error: ServiceFailure())
        try await waitUntil { !model.hasActiveOperations }
        #expect(model.selectedProject?.status == .failed)
    }

    @Test(arguments: [false, true])
    func cleanupFailureRemainsVisibleAndDoesNotRemoveProject(removing: Bool) async throws {
        let build = ControlledBuildService()
        let sim = ControlledSimulatorService([simulator("Phone")])
        defer { build.releaseAll(); sim.releaseAll() }
        let model = makeModel([project("App")], service: build, simulatorService: sim)
        await model.refreshSimulators()
        model.run()
        try await waitUntil { build.requests.count == 1 }
        build.complete(0)
        try await waitUntil { sim.requests.count == 1 }
        sim.launch(0)
        if removing { model.removeProject() } else { model.stop() }
        sim.complete(0, error: ToolchainError.cleanupFailed("Unable to terminate owned app"))
        try await waitUntil { !model.hasActiveOperations }
        #expect(model.projects.count == 1)
        #expect(model.selectedProject?.status == .failed)
        #expect(model.errorMessage != nil)
        #expect(model.logStore(for: model.selectedProjectID!).entries.last?.level == .error)
        model.removeProject()
        #expect(model.projects.count == 1)
        #expect(!model.canBuild && !model.canRemove)
        #expect(await model.shutdown())
    }

    @Test(arguments: [false, true])
    func shutdownFailurePreservesUsabilityAndRetriesOwnedCleanup(alreadyStopped: Bool) async throws {
        let build = ControlledBuildService()
        let sim = ControlledSimulatorService([simulator("Phone")])
        defer { build.releaseAll(); sim.releaseAll() }
        let model = makeModel([project("App")], service: build, simulatorService: sim)
        await model.refreshSimulators()
        model.run()
        try await waitUntil { build.requests.count == 1 }
        build.complete(0)
        try await waitUntil { sim.requests.count == 1 }
        sim.launch(0)
        let failure = ToolchainError.cleanupFailed("Unable to terminate owned app")
        sim.cleanupRetryError = failure
        if alreadyStopped {
            model.stop()
            sim.complete(0, error: failure)
            try await waitUntil { !model.hasActiveOperations }
        }
        let shutdown = Task { await model.shutdown() }
        if !alreadyStopped {
            try await waitUntil { model.isStopping }
            sim.complete(0, error: failure)
        }
        #expect(await shutdown.value == false)
        #expect(sim.pendingCleanup == [0])
        #expect(model.projects.count == 1 && model.selectedProject?.status == .failed)
        #expect(model.errorMessage != nil)
        #expect(!model.canBuild && !model.canRemove && model.canUseTools)
        #expect(!model.hasActiveOperations)

        sim.cleanupRetryError = nil
        #expect(await model.shutdown())
        #expect(sim.pendingCleanup.isEmpty)
        #expect(!model.canBuild && !model.canRemove && !model.canUseTools)
        model.resumeAfterCancelledShutdown()
        #expect(model.canBuild && model.canRemove)
    }

    @Test func failedWindowCleanupRetainsModelUntilSuccessfulRetry() async throws {
        let build = ControlledBuildService()
        let sim = ControlledSimulatorService([simulator("Phone")])
        defer { build.releaseAll(); sim.releaseAll() }
        let lifecycle = AppLifecycle()
        var model: DashboardViewModel? = makeModel([project("App")], service: build, simulatorService: sim)
        weak let retainedModel = model
        lifecycle.register(try #require(model))
        await model?.refreshSimulators()
        model?.run()
        try await waitUntil { build.requests.count == 1 }
        build.complete(0)
        try await waitUntil { sim.requests.count == 1 }
        sim.launch(0)
        model?.stop()
        let failure = ToolchainError.cleanupFailed("Unable to terminate owned app")
        sim.cleanupRetryError = failure
        sim.complete(0, error: failure)
        try await waitUntil { model?.hasActiveOperations == false }
        #expect(await lifecycle.close(try #require(model)) == false)
        model = nil
        #expect(retainedModel != nil)
        sim.cleanupRetryError = nil
        #expect(await lifecycle.close(try #require(retainedModel)))
        #expect(retainedModel == nil)
        #expect(sim.pendingCleanup.isEmpty)
    }

    @Test func shutdownDrainsDiscoveryInventoryAndToolsAndRejectsLateResults() async throws {
        let build = ControlledBuildService()
        build.holdDiscovery = true
        let sim = ControlledSimulatorService([simulator("Phone")])
        sim.holdInventory = true
        sim.holdOpen = true
        defer { build.releaseAll(); sim.releaseAll() }
        let existing = project("Existing")
        let model = makeModel([existing], service: build, simulatorService: sim)
        let importing = Task { await model.importProject(at: URL(fileURLWithPath: "/Test/Late.xcodeproj")) }
        let refreshing = Task { await model.refreshSimulators() }
        model.openSimulator()
        try await waitUntil {
            build.discoveryPending != nil && sim.inventoryPending != nil && sim.openPending != nil
        }
        var finished = false
        let shutdown = Task { finished = await model.shutdown() }
        try await waitUntil { !model.canRemove }
        #expect(!finished && model.hasActiveOperations)
        build.finishDiscovery(project("Late"))
        sim.finishInventory()
        await importing.value
        await refreshing.value
        #expect(!finished && model.hasActiveOperations)
        sim.finishOpen()
        await shutdown.value
        #expect(finished)
        #expect(await model.shutdown())
        #expect(!model.hasActiveOperations && model.simulators.isEmpty)
        #expect(model.projects.map(\.id) == [existing.id])
        #expect(model.errorMessage == nil)
    }

    @Test func shutdownWaitsForEveryOwnedOperationAndBlocksNewWork() async throws {
        let service = ControlledBuildService()
        defer { service.releaseAll() }
        let apps = [project("One"), project("Two")]
        let model = makeModel(apps, service: service)
        model.build()
        try await waitUntil { service.requests.count == 1 }
        model.selectProject(apps[1].id)
        model.clean()
        try await waitUntil { service.requests.count == 2 }
        model.showProjectPicker(.build)
        var finished = false
        let shutdown = Task { finished = await model.shutdown() }
        try await waitUntil { model.isStopping }
        #expect(!finished && !model.canBuild && !model.canRemove)
        #expect(!model.canChooseProject && model.projectPickerMode == nil)
        model.selectProject(at: 0)
        model.selectAdjacentProject(offset: 1)
        model.selectProject(apps[0].id)
        model.showProjectPicker(.switchProject)
        #expect(!model.chooseProject(apps[0].id, build: false))
        #expect(!model.chooseProject(apps[0].id, build: true))
        #expect(model.selectedProjectID == apps[1].id && model.projectPickerMode == nil)
        service.complete(0)
        await Task.yield()
        #expect(!finished)
        service.complete(1)
        await shutdown.value
        #expect(finished && !model.hasActiveOperations)
        #expect(model.projects.allSatisfy { $0.status == .stopped })
        model.build()
        #expect(!model.hasActiveOperations)
    }

    @Test func sameProjectAcrossWindowsCannotCleanUntilRunCleanupCompletes() async throws {
        let build = ControlledBuildService()
        let sim = ControlledSimulatorService([simulator("Phone")])
        let otherBuild = ControlledBuildService()
        defer { build.releaseAll(); sim.releaseAll(); otherBuild.releaseAll() }
        let app = project("Shared")
        let other = project("Other")
        let first = makeModel([app], service: build, simulatorService: sim)
        let second = makeModel([other, app], service: otherBuild)
        await first.refreshSimulators()
        first.run()
        try await waitUntil { build.requests.count == 1 }
        second.showProjectPicker(.build)
        #expect(!second.canBuildProject(app.id))
        #expect(!second.chooseProject(app.id, build: true))
        #expect(second.selectedProjectID == other.id && second.projectPickerMode == .build)
        #expect(second.chooseProject(app.id, build: false))
        #expect(!second.canBuild && !second.canClean)
        second.clean()
        #expect(otherBuild.requests.isEmpty)
        build.complete(0)
        try await waitUntil { sim.requests.count == 1 }
        sim.launch(0)
        #expect(!second.canClean)
        first.stop()
        #expect(!second.canClean)
        sim.complete(0)
        try await waitUntil { !first.hasActiveOperations }
        #expect(second.canClean)
        second.clean()
        try await waitUntil { otherBuild.requests.count == 1 }
        otherBuild.complete(0)
        try await waitUntil { !second.hasActiveOperations }
        #expect(second.selectedProject?.status == .idle)
    }

    @Test func runLocksCapturedDeviceAcrossWindowsUntilBuildCancellationDrains() async throws {
        let phone = simulator("Owned", status: .booted)
        let other = simulator("Other", status: .booted)
        let build = ControlledBuildService()
        defer { build.releaseAll() }
        let first = makeModel([project("First", destination: phone.id)], service: build,
                              simulatorService: ControlledSimulatorService([phone, other]))
        let second = makeModel([project("Second")], simulatorService: ControlledSimulatorService([phone, other]))
        await first.refreshSimulators()
        await second.refreshSimulators()
        first.run()
        #expect(!second.canSimulatorAction(.shutdown, on: phone.id))
        #expect(!second.canSimulatorAction(.restart, on: phone.id))
        #expect(second.canSimulatorAction(.show, on: phone.id))
        #expect(second.canSimulatorAction(.screenshot, on: phone.id))
        #expect(second.canSimulatorAction(.openURL, on: phone.id))
        #expect(!second.canSimulatorAction(.stopApp, on: phone.id))
        first.setSimulator(other.id)
        #expect(first.canSimulatorAction(.stopApp, on: phone.id))
        #expect(!first.canSimulatorAction(.stopApp, on: other.id))
        first.performSimulatorAction(.stopApp, on: other.id)
        #expect(!first.isStopping)
        try await waitUntil { build.requests.count == 1 }
        first.performSimulatorAction(.stopApp, on: phone.id)
        #expect(first.isStopping)
        #expect(!second.canSimulatorAction(.shutdown, on: phone.id))
        build.complete(0)
        try await waitUntil { !first.hasActiveOperations }
        #expect(second.canSimulatorAction(.shutdown, on: phone.id))
        #expect(build.artifactRequests.isEmpty)
    }

    @Test func shutdownConfirmationRevalidatesWhenAnotherWindowStartsRun() async throws {
        let phone = simulator("Phone", status: .booted)
        let build = ControlledBuildService()
        defer { build.releaseAll() }
        let service = ControlledSimulatorService([phone])
        let manager = makeModel([], simulatorService: service)
        let runner = makeModel([project("App")], service: build,
                               simulatorService: ControlledSimulatorService([phone]))
        await manager.refreshSimulators()
        await runner.refreshSimulators()
        manager.performSimulatorAction(.shutdown, on: phone.id)
        #expect(manager.simulatorConfirmation?.simulator.id == phone.id)
        runner.run()
        manager.confirmSimulatorAction()
        #expect(manager.simulatorConfirmation == nil)
        #expect(service.deviceRequests.isEmpty)
        try await waitUntil { build.requests.count == 1 }
        runner.stop()
        build.complete(0)
        try await waitUntil { !runner.hasActiveOperations }
    }

    @Test func failedCleanupKeepsDeviceLockedUntilSuccessfulRetry() async throws {
        let phone = simulator("Phone", status: .booted)
        let build = ControlledBuildService()
        let service = ControlledSimulatorService([phone])
        defer { build.releaseAll(); service.releaseAll() }
        let model = makeModel([project("App")], service: build, simulatorService: service)
        let other = makeModel([], simulatorService: ControlledSimulatorService([phone]))
        await model.refreshSimulators()
        await other.refreshSimulators()
        model.run()
        try await waitUntil { build.requests.count == 1 }
        build.complete(0)
        try await waitUntil { service.requests.count == 1 }
        service.launch(0)
        model.stop()
        let failure = ToolchainError.cleanupFailed("Still owns app")
        service.complete(0, error: failure)
        try await waitUntil { !model.hasActiveOperations }
        #expect(!other.canSimulatorAction(.shutdown, on: phone.id))
        service.cleanupRetryError = failure
        #expect(await model.shutdown() == false)
        #expect(!other.canSimulatorAction(.restart, on: phone.id))
        service.cleanupRetryError = nil
        #expect(await model.shutdown())
        #expect(other.canSimulatorAction(.shutdown, on: phone.id))
    }

    @Test func runHereRejectsInvalidSettingsAndTransitionalDevicesBeforeChangingDestination() async {
        let phone = simulator("Phone")
        let booting = simulator("Booting", status: .booting)
        let unavailable = simulator("Unavailable", status: .unavailable)
        let other = simulator("Other")
        var app = project("Invalid", destination: phone.id)
        app.scheme = "Missing"
        let model = makeModel([app], simulatorService: ControlledSimulatorService([phone, booting, unavailable, other]))
        await model.refreshSimulators()
        model.performSimulatorAction(.runProject, on: other.id)
        #expect(model.selectedProject?.selectedSimulatorID == phone.id)
        model.setScheme("App")
        for device in [booting, unavailable] {
            model.performSimulatorAction(.runProject, on: device.id)
            #expect(model.selectedProject?.selectedSimulatorID == phone.id)
        }
        #expect(!model.hasActiveOperations)
    }

    @Test func managementBlocksRunHereAndShutdownDrainsLateDeviceCompletion() async throws {
        let phone = simulator("Phone")
        let other = simulator("Other")
        let service = ControlledSimulatorService([phone, other])
        service.holdDevice = true
        defer { service.releaseAll() }
        let manager = makeModel([], simulatorService: service)
        let runner = makeModel([project("App", destination: other.id)],
                               simulatorService: ControlledSimulatorService([phone, other]))
        await manager.refreshSimulators()
        await runner.refreshSimulators()
        manager.performSimulatorAction(.bootAndOpen, on: phone.id)
        try await waitUntil { service.devicePending != nil }
        runner.performSimulatorAction(.runProject, on: phone.id)
        #expect(runner.selectedProject?.selectedSimulatorID == other.id)
        #expect(!runner.hasActiveOperations)
        var closed = false
        let closing = Task { closed = await manager.shutdown() }
        try await waitUntil { !manager.canChooseProject }
        #expect(!closed)
        #expect(!runner.canSimulatorAction(.runProject, on: phone.id))
        service.finishDevice()
        await closing.value
        #expect(closed)
        #expect(manager.simulators.first?.status == .available)
        #expect(manager.errorMessage == nil)
        #expect(runner.canSimulatorAction(.runProject, on: phone.id))
    }

    @Test func olderInventoryCannotOverwriteCompletedDeviceAction() async throws {
        let phone = simulator("Phone")
        let service = ControlledSimulatorService([phone])
        defer { service.releaseAll() }
        let model = makeModel([], simulatorService: service)
        await model.refreshSimulators()
        service.holdInventory = true
        let refresh = Task { await model.refreshSimulators() }
        try await waitUntil { service.inventoryPending != nil }
        service.holdInventory = false
        model.performSimulatorAction(.bootAndOpen, on: phone.id)
        try await waitUntil { model.simulators.first?.status == .booted && model.simulatorActivity(phone.id) == nil }
        service.inventory = [phone]
        service.finishInventory()
        await refresh.value
        #expect(model.simulators.first?.status == .booted)
    }

    @Test func unrelatedDeviceActivityDoesNotDiscardInventoryRefresh() async throws {
        let phone = simulator("Phone")
        let newlyDiscovered = simulator("New Phone")
        let service = ControlledSimulatorService([phone])
        defer { service.releaseAll() }
        let model = makeModel([], simulatorService: service)
        await model.refreshSimulators()
        service.holdInventory = true
        let refresh = Task { await model.refreshSimulators() }
        try await waitUntil { service.inventoryPending != nil }
        let lease = try #require(SimulatorOperationRegistry.shared.acquire(
            .management, on: UUID(), label: "Unrelated device"
        ))
        defer { SimulatorOperationRegistry.shared.release(lease) }
        service.inventory = [phone, newlyDiscovered]
        service.finishInventory()
        await refresh.value
        #expect(model.simulators.map(\.id) == [phone.id, newlyDiscovered.id])
    }

    @Test func deviceFailureSurvivesFailedInventoryRefresh() async throws {
        let phone = simulator("Phone")
        let service = ControlledSimulatorService([phone])
        defer { service.releaseAll() }
        let model = makeModel([], simulatorService: service)
        await model.refreshSimulators()
        service.holdDevice = true
        model.performSimulatorAction(.bootAndOpen, on: phone.id)
        try await waitUntil { service.devicePending != nil }
        service.inventoryError = ToolchainError.message("Inventory unavailable")
        let continuation = service.devicePending
        service.devicePending = nil
        continuation?.resume(throwing: ToolchainError.message("Device unreachable"))
        try await waitUntil { model.simulatorActivity(phone.id) == nil }
        #expect(model.errorMessage?.contains("Device unreachable") == true)
        #expect(model.errorMessage?.contains("Inventory unavailable") == false)
    }

    @Test func otherWindowActionDoesNotPreserveOlderLocalInventory() async throws {
        let phone = simulator("Phone", status: .booted)
        let service = ControlledSimulatorService([phone])
        defer { service.releaseAll() }
        let observer = makeModel([], simulatorService: service)
        let manager = makeModel([], simulatorService: service)
        await observer.refreshSimulators()
        await manager.refreshSimulators()
        service.holdInventory = true
        let refresh = Task { await observer.refreshSimulators() }
        try await waitUntil { service.inventoryPending != nil }
        service.holdInventory = false
        manager.performSimulatorAction(.shutdown, on: phone.id)
        manager.confirmSimulatorAction()
        try await waitUntil { manager.simulatorActivity(phone.id) == nil }
        service.finishInventory()
        await refresh.value
        #expect(observer.simulators.first?.status == .available)
        #expect(manager.simulators.first?.status == .available)
    }

    @Test func importedWorkspaceRestoresOrderChoicesAndIdentityWithoutDiscovery() async throws {
        try await withWorkspace { defaults, directory in
            let firstURL = directory.appendingPathComponent("First.xcodeproj")
            let secondURL = directory.appendingPathComponent("Second.xcodeproj")
            try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)
            let phone = simulator("Chosen Phone")
            let build = ControlledBuildService()
            let store = WorkspaceStore(defaults: defaults)
            let model = DashboardViewModel(buildService: build,
                                           simulatorService: ControlledSimulatorService([phone]),
                                           workspaceStore: store)
            await model.refreshSimulators()
            var first = project("First")
            first.path = firstURL.path
            first.status = .running
            first.issues = [BuildIssue(severity: .warning, message: "Previous issue", file: first.path, line: 1)]
            build.discoveredProject = first
            await model.importProject(at: firstURL)
            model.setScheme("AppTests")
            model.setConfiguration("Release")
            model.setSimulator(phone.id)
            var second = project("Second")
            second.path = secondURL.path
            build.discoveredProject = second
            await model.importProject(at: secondURL)
            model.setConfiguration("Review")
            model.setSimulator(nil)
            model.selectProject(first.id)
            model.logStore(for: first.id).append(BuildLogEntry(level: .error, message: "Old output"))
            model.logStore(for: first.id).flush()

            let restoredBuild = ControlledBuildService()
            let restored = DashboardViewModel(buildService: restoredBuild,
                                              simulatorService: ControlledSimulatorService([phone]),
                                              workspaceStore: WorkspaceStore(defaults: defaults))
            await restored.refreshSimulators()
            #expect(restored.projects.map(\.id) == [first.id, second.id])
            #expect(restored.projects.map(\.path) == [firstURL.resolvingSymlinksInPath().path,
                                                     secondURL.resolvingSymlinksInPath().path])
            #expect(restored.selectedProjectID == first.id)
            #expect(restored.projects.map(\.scheme) == ["AppTests", "App"])
            #expect(restored.projects.map(\.configuration) == ["Release", "Review"])
            #expect(restored.projects.map(\.selectedSimulatorID) == [phone.id, nil])
            #expect(restored.projects.allSatisfy { $0.status == .idle && $0.issues.isEmpty })
            #expect(restored.logStore(for: first.id).entries.isEmpty)
            #expect(restoredBuild.discoveryURLs.isEmpty && restoredBuild.requests.isEmpty)
        }
    }

    @Test func missingRestoredProjectsRemainVisibleWithRecoveryInstructions() async throws {
        try await withWorkspace { defaults, directory in
            var missing = project("Disconnected")
            missing.path = directory.appendingPathComponent("Disconnected.xcodeproj").path
            missing.status = .running
            missing.issues = [BuildIssue(severity: .warning, message: "Old diagnostic", file: "", line: 1)]
            let store = WorkspaceStore(defaults: defaults)
            store.add(missing)
            store.selectProject(missing.id)
            let build = ControlledBuildService()
            let restored = DashboardViewModel(buildService: build, simulatorService: ControlledSimulatorService(),
                                              workspaceStore: WorkspaceStore(defaults: defaults))
            let visible = try #require(restored.selectedProject)
            #expect(visible.id == missing.id && visible.path == missing.path)
            #expect(visible.status == .failed)
            #expect(visible.issues.count == 1)
            #expect(visible.issues[0].severity == .error)
            #expect(visible.issues[0].message.contains(missing.path))
            #expect(!restored.hasActiveOperations && restored.canRemove)
            #expect(build.discoveryURLs.isEmpty)
            restored.removeProject()
            let reopened = WorkspaceStore(defaults: defaults)
            #expect(reopened.workspace.projects.isEmpty && reopened.workspace.selectedProjectID == nil)
        }
    }

    @Test func staleAndEmptyWindowsCannotEraseImportsOrResurrectRemovedProjects() async throws {
        try await withWorkspace { defaults, directory in
            let store = WorkspaceStore(defaults: defaults)
            let firstBuild = ControlledBuildService()
            let secondBuild = ControlledBuildService()
            let first = DashboardViewModel(buildService: firstBuild, simulatorService: ControlledSimulatorService(),
                                           workspaceStore: store)
            let second = DashboardViewModel(buildService: secondBuild, simulatorService: ControlledSimulatorService(),
                                            workspaceStore: store)
            var a = project("A")
            a.path = directory.appendingPathComponent("A.xcodeproj").path
            var b = project("B")
            b.path = directory.appendingPathComponent("B.xcodeproj").path
            firstBuild.discoveredProject = a
            secondBuild.discoveredProject = b
            await first.importProject(at: URL(fileURLWithPath: a.path))
            await second.importProject(at: URL(fileURLWithPath: b.path))
            first.setScheme("AppTests")
            second.setConfiguration("Release")
            let stale = DashboardViewModel(buildService: ControlledBuildService(),
                                           simulatorService: ControlledSimulatorService(), workspaceStore: store)
            #expect(stale.projects.map(\.id) == [a.id, b.id])
            #expect(stale.projects[0].scheme == "AppTests")
            #expect(stale.projects[1].configuration == "Release")
            stale.selectProject(a.id)
            second.selectProject(b.id)
            first.removeProject()
            stale.setConfiguration("Review")
            stale.setSimulator(nil)
            stale.selectProject(a.id)
            #expect(await first.shutdown())
            let saved = WorkspaceStore(defaults: defaults).workspace
            #expect(saved.projects.map(\.id) == [b.id])
            #expect(saved.projects[0].configuration == "Release")
            #expect(saved.selectedProjectID == b.id)
        }
    }

    @Test func restoredSimulatorChoiceSurvivesUnavailableAndEmptyInventories() async throws {
        try await withWorkspace { defaults, _ in
            let chosen = simulator("Chosen", status: .unavailable)
            let other = simulator("Other")
            let app = project("App", destination: chosen.id)
            let store = WorkspaceStore(defaults: defaults)
            store.add(app)
            store.selectProject(app.id)
            let inventory = ControlledSimulatorService([chosen, other])
            let model = DashboardViewModel(buildService: ControlledBuildService(),
                                           simulatorService: inventory, workspaceStore: store)
            await model.refreshSimulators()
            #expect(model.selectedProject?.selectedSimulatorID == chosen.id && !model.canRun)
            inventory.inventory = []
            await model.refreshSimulators()
            #expect(WorkspaceStore(defaults: defaults).workspace.projects[0].selectedSimulatorID == chosen.id)
            inventory.inventory = [other]
            await model.refreshSimulators()
            model.setSimulator(other.id)
            #expect(WorkspaceStore(defaults: defaults).workspace.projects[0].selectedSimulatorID == other.id)
        }
    }

    @Test func constructionShutdownAndTransientModelsDoNotWriteWorkspace() async throws {
        try await withWorkspace { defaults, _ in
            let store = WorkspaceStore(defaults: defaults)
            let app = project("Saved")
            store.add(app)
            store.selectProject(app.id)
            let before = defaults.data(forKey: WorkspaceStore.storageKey)
            let model = DashboardViewModel(buildService: ControlledBuildService(),
                                           simulatorService: ControlledSimulatorService(), workspaceStore: store)
            let transient = makeModel([project("Fixture")])
            transient.removeProject()
            #expect(await transient.shutdown())
            #expect(await model.shutdown())
            #expect(defaults.data(forKey: WorkspaceStore.storageKey) == before)
            let reopened = DashboardViewModel(buildService: ControlledBuildService(),
                                              simulatorService: ControlledSimulatorService(),
                                              workspaceStore: WorkspaceStore(defaults: defaults))
            #expect(reopened.selectedProjectID == app.id)
        }
    }

    @Test func corruptWorkspaceIsReportedAndNeverOverwrittenByEmptyWindow() async throws {
        try await withWorkspace { defaults, _ in
            let corrupt = Data("unreadable saved workspace".utf8)
            defaults.set(corrupt, forKey: WorkspaceStore.storageKey)
            let store = WorkspaceStore(defaults: defaults)
            let model = DashboardViewModel(buildService: ControlledBuildService(),
                                           simulatorService: ControlledSimulatorService(), workspaceStore: store)
            #expect(model.errorMessage != nil)
            store.add(project("New"))
            store.selectProject(nil)
            #expect(await model.shutdown())
            #expect(defaults.data(forKey: WorkspaceStore.storageKey) == corrupt)
        }
    }

    @Test func explicitlyClearedProjectSelectionRemainsClearedOnRelaunch() async throws {
        try await withWorkspace { defaults, _ in
            let store = WorkspaceStore(defaults: defaults)
            let app = project("Saved")
            store.add(app)
            store.selectProject(app.id)
            let model = DashboardViewModel(buildService: ControlledBuildService(),
                                           simulatorService: ControlledSimulatorService(), workspaceStore: store)
            model.selectProject(nil)
            let reopened = DashboardViewModel(buildService: ControlledBuildService(),
                                              simulatorService: ControlledSimulatorService(),
                                              workspaceStore: WorkspaceStore(defaults: defaults))
            #expect(reopened.projects.map(\.id) == [app.id])
            #expect(reopened.selectedProjectID == nil)
        }
    }

    private func withWorkspace(_ body: (UserDefaults, URL) async throws -> Void) async throws {
        let suite = "SwiftDeckTests.Workspace.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try await body(defaults, directory)
    }

    private func makeModel(
        _ projects: [ProjectModel], service: ControlledBuildService? = nil,
        simulatorService: ControlledSimulatorService? = nil, selectedID: UUID? = nil
    ) -> DashboardViewModel {
        DashboardViewModel(projects: projects, buildService: service ?? ControlledBuildService(),
                           simulatorService: simulatorService ?? ControlledSimulatorService([simulator("Phone")]),
                           selectedProjectID: selectedID)
    }

    private func project(_ name: String, destination: UUID? = nil) -> ProjectModel {
        ProjectModel(name: name, path: "/Test/\(name).xcodeproj", schemes: ["App", "AppTests"], scheme: "App",
                     configurations: ["Debug", "Release", "Review"], configuration: "Debug", selectedSimulatorID: destination)
    }

    private func simulator(_ name: String, status: SimulatorStatus = .available) -> SimulatorModel {
        SimulatorModel(id: UUID(), name: name, runtime: "iOS 18.0", status: status, storageBytes: nil)
    }

    private func conflict(on simulator: SimulatorModel) -> RunningAppConflict {
        RunningAppConflict(bundleIdentifier: "test.app", simulatorID: simulator.id,
                           simulatorName: simulator.name, pid: 4321)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TestTimeout() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

/// Deliberately holds cancellation until the test releases cleanup; late callbacks remain callable.
@MainActor
private final class ControlledBuildService: BuildServiceProtocol {
    private(set) var requests: [BuildContext] = []
    private(set) var cleanRequests: [Int] = []
    private(set) var discoveryURLs: [URL] = []
    var discoveredProject: ProjectModel?
    var discoveryError: (any Error)?
    var holdDiscovery = false
    var discoveryPending: CheckedContinuation<ProjectModel, any Error>?
    private(set) var artifactRequests: [BuildContext] = []
    var artifactError: (any Error)?
    var holdArtifactDiscovery = false
    var artifactPending: CheckedContinuation<Void, any Error>?
    private var pending: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var outputs: [Int: @MainActor (String) -> Void] = [:]

    func discoverProject(at url: URL) async throws -> ProjectModel {
        discoveryURLs.append(url)
        if let discoveryError { throw discoveryError }
        if holdDiscovery {
            return try await withCheckedThrowingContinuation { discoveryPending = $0 }
        }
        guard let discoveredProject else { throw ServiceFailure() }
        return discoveredProject
    }

    func finishDiscovery(_ project: ProjectModel) {
        let continuation = discoveryPending
        discoveryPending = nil
        continuation?.resume(returning: project)
    }

    func build(_ context: BuildContext, onOutput: @escaping @MainActor (String) -> Void) async throws {
        try await request(context, clean: false, onOutput: onOutput)
    }

    func builtApplication(_ context: BuildContext) async throws -> BuildArtifact {
        artifactRequests.append(context)
        if let artifactError { throw artifactError }
        if holdArtifactDiscovery {
            try await withCheckedThrowingContinuation { artifactPending = $0 }
        }
        return BuildArtifact(appURL: URL(fileURLWithPath: "/Test/Build/App.app"), bundleIdentifier: "test.app")
    }

    func finishArtifactDiscovery(error: (any Error)? = nil) {
        guard let continuation = artifactPending else {
            Issue.record("No pending artifact discovery")
            return
        }
        artifactPending = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    func clean(_ context: BuildContext, onOutput: @escaping @MainActor (String) -> Void) async throws {
        try await request(context, clean: true, onOutput: onOutput)
    }

    private func request(_ context: BuildContext, clean: Bool, onOutput: @escaping @MainActor (String) -> Void) async throws {
        let index = requests.count
        requests.append(context)
        outputs[index] = onOutput
        if clean { cleanRequests.append(index) }
        try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func output(_ index: Int, _ line: String) { outputs[index]?(line) }

    func complete(_ index: Int, error: (any Error)? = nil) {
        guard let continuation = pending.removeValue(forKey: index) else {
            Issue.record("No pending build operation at index \(index)")
            return
        }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    func releaseAll() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
        discoveryPending?.resume(throwing: CancellationError())
        discoveryPending = nil
        artifactPending?.resume(throwing: CancellationError())
        artifactPending = nil
    }
}

@MainActor
private final class ControlledSimulatorService: SimulatorServiceProtocol {
    var inventory: [SimulatorModel]
    var inventoryError: (any Error)?
    var holdInventory = false
    var holdOpen = false
    var holdDevice = false
    var devicePending: CheckedContinuation<Void, any Error>?
    private(set) var deviceRequests: [(SimulatorDeviceAction, UUID)] = []
    private(set) var openedTargets: [UUID?] = []
    private(set) var openedURLs: [(URL, UUID)] = []
    private(set) var screenshotDestinations: [(UUID, URL)] = []
    var screenshotData: Data?
    var inventoryPending: CheckedContinuation<[SimulatorModel], any Error>?
    var openPending: CheckedContinuation<Void, any Error>?
    var cleanupRetryError: (any Error)?
    private(set) var pendingCleanup: Set<Int> = []
    private(set) var requests: [UUID] = []
    var conflicts: [UUID: RunningAppConflict] = [:]
    private(set) var conflictRequests: [Int] = []
    private var pending: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var launches: [Int: @MainActor (Int32) -> Void] = [:]

    init(_ inventory: [SimulatorModel] = []) { self.inventory = inventory }

    func loadSimulators() async throws -> [SimulatorModel] {
        if let inventoryError { throw inventoryError }
        if holdInventory {
            return try await withCheckedThrowingContinuation { inventoryPending = $0 }
        }
        return inventory
    }

    func run(_ artifact: BuildArtifact, on simulatorID: UUID, onOutput: @escaping @MainActor (String) -> Void,
             onLaunch: @escaping @MainActor (Int32) -> Void,
             onConflict: @escaping @MainActor (RunningAppConflict) async -> Bool) async throws {
        let index = requests.count
        requests.append(simulatorID)
        if let conflict = conflicts[simulatorID] {
            conflictRequests.append(index)
            guard await onConflict(conflict) else { throw CancellationError() }
            try Task.checkCancellation()
        }
        launches[index] = onLaunch
        try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func openSimulator(on simulatorID: UUID?) async throws {
        openedTargets.append(simulatorID)
        if holdOpen {
            try await withCheckedThrowingContinuation { openPending = $0 }
        }
    }

    func bootAndOpen(_ simulatorID: UUID) async throws {
        try await deviceRequest(.bootAndOpen, on: simulatorID, status: .booted)
    }

    func shutdown(_ simulatorID: UUID) async throws {
        try await deviceRequest(.shutdown, on: simulatorID, status: .available)
    }

    func restart(_ simulatorID: UUID) async throws {
        try await deviceRequest(.restart, on: simulatorID, status: .booted)
    }

    func screenshot(_ simulatorID: UUID, to url: URL) async throws {
        screenshotDestinations.append((simulatorID, url))
        if let screenshotData { try screenshotData.write(to: url) }
    }

    func openURL(_ url: URL, on simulatorID: UUID) async throws {
        openedURLs.append((url, simulatorID))
    }

    private func deviceRequest(_ action: SimulatorDeviceAction, on id: UUID, status: SimulatorStatus) async throws {
        deviceRequests.append((action, id))
        if holdDevice {
            try await withCheckedThrowingContinuation { devicePending = $0 }
        }
        if let index = inventory.firstIndex(where: { $0.id == id }) {
            inventory[index].status = status
        }
    }

    func finishDevice() {
        let continuation = devicePending
        devicePending = nil
        continuation?.resume()
    }

    func retryPendingCleanup() async throws {
        guard !pendingCleanup.isEmpty else { return }
        if let cleanupRetryError { throw cleanupRetryError }
        pendingCleanup.removeAll()
    }

    func finishInventory() {
        let continuation = inventoryPending
        inventoryPending = nil
        continuation?.resume(returning: inventory)
    }

    func finishOpen() {
        let continuation = openPending
        openPending = nil
        continuation?.resume()
    }
    func launch(_ index: Int) { launches[index]?(1234) }

    func isReadyToLaunch(_ index: Int) -> Bool { pending[index] != nil }

    func complete(_ index: Int, error: (any Error)? = nil) {
        guard let continuation = pending.removeValue(forKey: index) else {
            Issue.record("No pending simulator operation at index \(index)")
            return
        }
        if let error = error as? ToolchainError, case .cleanupFailed = error {
            pendingCleanup.insert(index)
        }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    func releaseAll() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
        inventoryPending?.resume(throwing: CancellationError())
        inventoryPending = nil
        openPending?.resume(throwing: CancellationError())
        openPending = nil
        devicePending?.resume(throwing: CancellationError())
        devicePending = nil
    }
}

private struct ServiceFailure: LocalizedError {
    var errorDescription: String? { "Controlled service failure" }
}

private struct TestTimeout: Error {}
