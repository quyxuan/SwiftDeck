import Combine
import CoreGraphics
import Foundation
import IOSurface
import FBSimulatorControl
import FBControlCore

/// Owns only a display/input connection, never the guest application's lifetime.
@MainActor
final class EmbeddedSimulatorSession: ObservableObject {
    let device: SimulatorModel
    @Published private(set) var isReady = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRotating = false
    @Published var controlError: String?
    @Published private(set) var isSilent: Bool?
    @Published private(set) var isChangingSilent = false
    @Published private(set) var displaySize = CGSize(width: 390, height: 844)
    private(set) var surface: IOSurface?
    private(set) var pointSize = CGSize.zero
    private(set) var rotation = 0
    private var legacyScreenScale: CGFloat?
    private var legacyOrientation: SimulatorDeviceOrientation = .portrait
    private var legacyInterfaceRotation = 0
    private var displayGeometry: SimulatorDisplayGeometry?
    private var isWaitingForGeometry = false
    private let onDeviceStateChange: @MainActor () -> Void

    private var lease: SimulatorOperationRegistry.Lease?
    private let backend = EmbeddedSimulatorBackend()
    private var hasInputConnection = false
    /// Render invalidation does not invalidate the SwiftUI view tree on every guest frame.
    let frameAvailable = PassthroughSubject<Void, Never>()
    private var preparation: Task<Void, Never>?
    private var frames: Task<Void, Never>?
    private var geometryUpdates: Task<Void, Never>?
    private var inputWorker: Task<Void, Never>?
    private var rotationTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var isClosing = false
    private var input: AsyncStream<InputOperation>.Continuation?
    private var gesture: SimulatorGestureBuffer?
    private var heldKeys = Set<UInt32>()
    private var keysAwaitingRelease = Set<UInt32>()
    private var contact: CGPoint?

    private enum InputOperation {
        case event(SimulatorHIDEvent)
        case gesture(AsyncThrowingStream<SimulatorHIDEvent, Error>, SimulatorDisplayGeometry?)
        case rotate
    }

    init(device: SimulatorModel, onDeviceStateChange: @escaping @MainActor () -> Void) throws {
        self.device = device
        self.onDeviceStateChange = onDeviceStateChange
        let kind: SimulatorOperationRegistry.Kind = device.status == .available ? .management : .display
        guard let lease = SimulatorOperationRegistry.shared.acquire(kind, on: device.id, label: "Embedded in SwiftDeck") else {
            throw ToolchainError.message("This simulator is busy or already embedded in another SwiftDeck window.")
        }
        self.lease = lease
        preparation = Task { [weak self] in await self?.prepare() }
    }

    isolated deinit {
        preparation?.cancel()
        frames?.cancel()
        geometryUpdates?.cancel()
        rotationTask?.cancel()
        audioTask?.cancel()
        gesture?.finish()
        input?.finish()
        inputWorker?.cancel()
        surface?.decrementUseCount()
        let backend = backend
        let lease = lease
        let keys = keysAwaitingRelease
        Task { @MainActor in
            if !keys.isEmpty {
                try? await backend.send(.composite(keys.map { .keyboard(direction: .up, keyCode: $0) }))
            }
            await backend.close()
            if let lease { SimulatorOperationRegistry.shared.release(lease) }
        }
    }

    private func prepare() async {
        defer { if device.status == .available { onDeviceStateChange() } }
        do {
            if device.status == .available {
                let runner = ProcessRunner()
                let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
                _ = try await runner.run(executable: xcrun, arguments: ["simctl", "boot", device.id.uuidString])
                _ = try await runner.run(
                    executable: xcrun, arguments: ["simctl", "bootstatus", device.id.uuidString, "-b"], timeoutSeconds: 180
                )
                try Task.checkCancellation()
                if let lease { SimulatorOperationRegistry.shared.release(lease) }
                lease = SimulatorOperationRegistry.shared.acquire(.display, on: device.id, label: "Embedded in SwiftDeck")
                guard lease != nil else { throw ToolchainError.message("Simulator display ownership changed while booting.") }
            }
            try Task.checkCancellation()
            let connection = try await backend.open(deviceID: device.id)
            hasInputConnection = true
            try Task.checkCancellation()
            if let geometry = connection.geometry {
                applyGeometry(geometry)
            } else {
                legacyScreenScale = connection.legacyScale
                legacyInterfaceRotation = connection.legacyRotation
                switch legacyInterfaceRotation {
                case 90: legacyOrientation = .landscapeRight
                case 180: legacyOrientation = .portraitUpsideDown
                case 270: legacyOrientation = .landscapeLeft
                default: legacyOrientation = .portrait
                }
            }
            startInput()
            if let settings = try? await backend.audioSettings() { isSilent = !settings.ringerEnabled }
            frames = Task { [weak self] in
                for await surface in connection.surfaces {
                    if Task.isCancelled { break }
                    guard let self else { break }
                    do {
                        if self.surface !== surface {
                            try await self.receiveSurface(surface)
                        }
                        self.frameAvailable.send()
                    } catch {
                        if !Task.isCancelled { self.fail(error) }
                        break
                    }
                }
            }
            geometryUpdates = Task { [weak self, backend] in
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(500))
                        guard await backend.isBooted() else {
                            throw ToolchainError.message("The simulator stopped. Close this panel and reopen it after booting.")
                        }
                        guard self?.isRotating == false else { continue }
                        if connection.geometry != nil {
                            do {
                                guard let updated = try await backend.geometry() else {
                                    throw ToolchainError.message("The simulator display mapping is no longer available.")
                                }
                                try Task.checkCancellation()
                                guard self?.isRotating == false else { continue }
                                self?.applyGeometry(updated)
                            } catch SimulatorDisplayError.changed, SimulatorDisplayError.transitioning {
                                self?.waitForDisplayGeometry()
                            }
                        } else {
                            let rotation = try await backend.legacyInterfaceRotation()
                            self?.applyLegacyInterfaceRotation(rotation)
                        }
                    }
                } catch {
                    if !Task.isCancelled { self?.fail(error) }
                }
            }
        } catch {
            if !Task.isCancelled && !isClosing { fail(error) }
        }
    }

    private func receiveSurface(_ next: IOSurface?) async throws {
        guard !isClosing else { return }
        if legacyScreenScale != nil || next == nil || isRotating {
            releaseInput()
            replaceSurface(next)
            return
        }
        isReady = false
        releaseInput()
        do {
            guard let geometry = try await backend.geometry() else {
                throw ToolchainError.message("The simulator display mapping is no longer available.")
            }
            try Task.checkCancellation()
            guard !isClosing else { return }
            applyGeometry(geometry)
            replaceSurface(next)
        } catch SimulatorDisplayError.changed, SimulatorDisplayError.transitioning {
            // Keep the new surface, but do not expose input until the next valid geometry read.
            replaceSurface(next)
            waitForDisplayGeometry()
        }
    }

    private func replaceSurface(_ next: IOSurface?) {
        next?.incrementUseCount()
        let previous = surface
        surface = next
        previous?.decrementUseCount()
        if let next, let scale = legacyScreenScale {
            // IOSurface and legacy Indigo HID both use the unrotated screen coordinates.
            let rawSize = CGSize(width: CGFloat(next.width) / scale, height: CGFloat(next.height) / scale)
            rotation = legacyInterfaceRotation
            pointSize = rotation == 90 || rotation == 270
                ? CGSize(width: rawSize.height, height: rawSize.width) : rawSize
            displaySize = pointSize
        }
        isReady = next != nil && hasInputConnection && !isClosing && errorMessage == nil
        frameAvailable.send()
    }

    private func applyGeometry(_ geometry: SimulatorDisplayGeometry) {
        displayGeometry = geometry
        let nextRotation: Int
        switch geometry.rotation {
        case .upright: nextRotation = 0
        case .clockwise: nextRotation = 90
        case .upsideDown: nextRotation = 180
        case .counterclockwise: nextRotation = 270
        }
        if pointSize != geometry.pointSize || rotation != nextRotation {
            releaseInput()
            pointSize = geometry.pointSize
            rotation = nextRotation
            displaySize = pointSize
            frameAvailable.send()
        }
        if isWaitingForGeometry {
            isWaitingForGeometry = false
            controlError = nil
        }
        if !isReady, surface != nil, hasInputConnection, !isClosing, errorMessage == nil {
            isReady = true
        }
    }

    private func waitForDisplayGeometry() {
        releaseInput()
        isReady = false
        isWaitingForGeometry = true
        controlError = "The simulator display is changing. Input will resume when its geometry settles."
    }

    private func releaseAbandonedGesture() {
        // The failed stream has no consumer; releases must go through the outer queue.
        gesture?.finish()
        gesture = nil
        contact = nil
        for key in keysAwaitingRelease {
            enqueueOperation(.event(.keyboard(direction: .up, keyCode: key)))
        }
        heldKeys.removeAll(keepingCapacity: true)
    }

    private func startInput() {
        let (operations, continuation) = AsyncStream.makeStream(
            of: InputOperation.self, bufferingPolicy: .bufferingOldest(64)
        )
        input = continuation
        inputWorker = Task { [weak self, backend] in
            do {
                for await operation in operations {
                    switch operation {
                    case .event(let event):
                        try await backend.send(event)
                        if case .keyboard(.up, let key) = event { self?.keysAwaitingRelease.remove(key) }
                    case .gesture(let events, let expectedGeometry):
                        do {
                            if let expectedGeometry {
                                let actual = try await backend.geometry()
                                guard actual == expectedGeometry else {
                                    self?.releaseAbandonedGesture()
                                    if let actual { self?.applyGeometry(actual) }
                                    continue
                                }
                            }
                            try await backend.send(events)
                        } catch SimulatorDisplayError.changed, SimulatorDisplayError.transitioning {
                            // HID cleans up contacts on their original display before throwing.
                            self?.releaseAbandonedGesture()
                            self?.waitForDisplayGeometry()
                            // Let the geometry poll recover readiness; first drain queued key releases.
                        }
                    case .rotate:
                        guard let self, !self.isClosing else { continue }
                        let task = Task { @MainActor [self] in await self.performRotation() }
                        self.rotationTask = task
                        await task.value
                        self.rotationTask = nil
                    }
                }
            } catch {
                if !Task.isCancelled { self?.fail(error) }
            }
        }
    }

    func sendTouch(down: Bool, x coordinateX: Double, y coordinateY: Double) {
        guard isReady, !isClosing, !isRotating, coordinateX.isFinite, coordinateY.isFinite,
              coordinateX >= 0, coordinateY >= 0,
              coordinateX <= pointSize.width, coordinateY <= pointSize.height else { return }
        if down, gesture == nil {
            let buffer = SimulatorGestureBuffer()
            gesture = buffer
            enqueueOperation(.gesture(buffer.events, displayGeometry))
        }
        guard let gesture else { return }
        let point = legacyTouchPoint(CGPoint(x: coordinateX, y: coordinateY))
        gesture.yield(.touch(direction: down ? .down : .up, x: point.x, y: point.y), isMotion: down && contact != nil)
        contact = down ? point : nil
        if !down {
            gesture.finish()
            self.gesture = nil
        }
    }

    func sendKey(usage: UInt32, down: Bool) {
        guard isReady, !isClosing, !isRotating else { return }
        if down {
            heldKeys.insert(usage)
            keysAwaitingRelease.insert(usage)
        } else {
            heldKeys.remove(usage)
        }
        enqueue(.keyboard(direction: down ? .down : .up, keyCode: usage))
    }

    func pressHome() {
        guard isReady, !isClosing, !isRotating else { return }
        releaseInput()
        enqueue(.shortButtonPress(.homeButton))
    }

    func pressHardwareButton(_ button: SimulatorHIDButton) {
        guard isReady, !isClosing, !isRotating else { return }
        if case .lock = button { releaseInput() }
        enqueue(.shortButtonPress(button))
    }

    func toggleSilent() {
        guard isReady, !isClosing, !isRotating, !isChangingSilent else { return }
        isChangingSilent = true
        controlError = nil
        audioTask = Task { [weak self, backend] in
            guard let self else { return }
            defer {
                self.isChangingSilent = false
                self.audioTask = nil
            }
            do {
                let currentlySilent = !(try await backend.audioSettings().ringerEnabled)
                try Task.checkCancellation()
                try await backend.setRingerEnabled(currentlySilent)
                try Task.checkCancellation()
                guard !isClosing else { return }
                isSilent = !currentlySilent
            } catch {
                if !Task.isCancelled && !isClosing {
                    controlError = "Unable to change Silent Mode: \(error.localizedDescription)"
                }
            }
        }
    }

    func rotateClockwise() {
        guard isReady, !isClosing, !isRotating else { return }
        controlError = nil
        isRotating = true
        // End the current contact and release keys before the queued rotation can run.
        releaseInput()
        enqueueOperation(.rotate)
    }

    private func performRotation() async {
        defer { isRotating = false }
        do {
            try Task.checkCancellation()
            let current: SimulatorDeviceOrientation
            if legacyScreenScale != nil {
                current = legacyOrientation
            } else {
                current = try await backend.orientation()
            }
            let desired: SimulatorDeviceOrientation
            switch current {
            case .portrait: desired = .landscapeRight
            case .landscapeRight: desired = .portraitUpsideDown
            case .portraitUpsideDown: desired = .landscapeLeft
            case .landscapeLeft: desired = .portrait
            case .unknown, .faceUp, .faceDown: desired = .portrait
            }
            try Task.checkCancellation()
            guard !isClosing else { return }
            try await backend.setOrientation(desired)
            if legacyScreenScale != nil {
                // Purple confirms delivery, but Xcode 26 has no physical-motion read service.
                // Track accepted writes for the next turn; never present that as physical readback.
                legacyOrientation = desired
                let expectedRotation = Self.rotation(for: desired)
                let deadline = ContinuousClock.now + .seconds(3)
                repeat {
                    try await Task.sleep(for: .milliseconds(100))
                    try Task.checkCancellation()
                    guard !isClosing else { return }
                    let observed = try await backend.legacyInterfaceRotation()
                    applyLegacyInterfaceRotation(observed)
                    if observed == expectedRotation { return }
                } while ContinuousClock.now < deadline
                controlError = "Rotation was sent, but the app kept a different interface orientation. It may lock rotation. This runtime cannot read back physical orientation."
                return
            }

            // A successful send is not confirmation that the guest accepted the physical rotation.
            let deadline = ContinuousClock.now + .seconds(3)
            var confirmed = false
            repeat {
                try await Task.sleep(for: .milliseconds(100))
                let observed = try await backend.orientation()
                try Task.checkCancellation()
                guard !isClosing else { return }
                if observed == desired {
                    confirmed = true
                    break
                }
            } while ContinuousClock.now < deadline
            guard confirmed else {
                throw ToolchainError.message("The simulator did not confirm the requested physical orientation. Check its orientation in Simulator and try Rotate again.")
            }

            if legacyScreenScale == nil {
                // The interface can settle after physical motion, or stay portrait when an app
                // locks orientation. Only reported geometry may change rendering and HID mapping.
                var previous: SimulatorDisplayGeometry?
                var stableReads = 0
                let geometryDeadline = ContinuousClock.now + .seconds(3)
                repeat {
                    try await Task.sleep(for: .milliseconds(200))
                    guard let geometry = try await backend.geometry() else {
                        throw ToolchainError.message("The simulator no longer reports display geometry. Close and reopen this embedded panel.")
                    }
                    try Task.checkCancellation()
                    guard !isClosing else { return }
                    applyGeometry(geometry)
                    stableReads = geometry == previous ? stableReads + 1 : 0
                    previous = geometry
                    if stableReads >= 2 { break }
                } while ContinuousClock.now < geometryDeadline
                guard stableReads >= 2 else {
                    throw ToolchainError.message("The simulator display is still changing. Wait for its interface to settle before trying Rotate again.")
                }
            }
        } catch SimulatorFrameworkBridgeError.binaryMissing {
            if !Task.isCancelled && !isClosing {
                controlError = "This runtime requires SimulatorFrameworkBridge to read physical orientation. Use Rotate in Simulator, or a SwiftDeck backend bundle containing that helper. No simulator or app was restarted."
            }
        } catch {
            if !Task.isCancelled && !isClosing {
                controlError = "Could not rotate the simulator: \(error.localizedDescription) Check the device in Simulator, then try Rotate again. No simulator or app was restarted."
            }
        }
    }

    private static func rotation(for orientation: SimulatorDeviceOrientation) -> Int {
        switch orientation {
        case .landscapeRight: 90
        case .portraitUpsideDown: 180
        case .landscapeLeft: 270
        case .portrait, .unknown, .faceUp, .faceDown: 0
        }
    }

    private func applyLegacyInterfaceRotation(_ nextRotation: Int) {
        guard legacyInterfaceRotation != nextRotation else { return }
        releaseInput()
        legacyInterfaceRotation = nextRotation
        if !isRotating {
            // An external interface change becomes the next clockwise command's baseline.
            switch nextRotation {
            case 90: legacyOrientation = .landscapeRight
            case 180: legacyOrientation = .portraitUpsideDown
            case 270: legacyOrientation = .landscapeLeft
            default: legacyOrientation = .portrait
            }
        }
        replaceSurface(surface)
    }

    private func legacyTouchPoint(_ point: CGPoint) -> CGPoint {
        guard legacyScreenScale != nil else { return point }
        // Modern HID applies this inverse itself; fallback Indigo only normalizes raw points.
        switch rotation {
        case 90: return CGPoint(x: point.y, y: pointSize.width - point.x)
        case 180: return CGPoint(x: pointSize.width - point.x, y: pointSize.height - point.y)
        case 270: return CGPoint(x: pointSize.height - point.y, y: point.x)
        default: return point
        }
    }

    private func enqueue(_ event: SimulatorHIDEvent) {
        if let gesture { gesture.yield(event) } else { enqueueOperation(.event(event)) }
    }

    private func enqueueOperation(_ operation: InputOperation) {
        guard let input else { return }
        if case .dropped = input.yield(operation) {
            // Never silently drop a key-up or retain an unbounded backlog behind a slow
            // transport. Close drains admitted work and explicitly releases every held key.
            fail(ToolchainError.message("Simulator input could not keep up. The display connection was closed to release input safely."))
        }
    }

    func releaseInput() {
        if let contact {
            gesture?.yield(.touch(direction: .up, x: contact.x, y: contact.y))
            self.contact = nil
        }
        for key in heldKeys { enqueue(.keyboard(direction: .up, keyCode: key)) }
        heldKeys.removeAll(keepingCapacity: true)
        gesture?.finish()
        gesture = nil
    }

    private func fail(_ error: Error) {
        guard !isClosing, errorMessage == nil else { return }
        errorMessage = error.localizedDescription
        isReady = false
        Task { [weak self] in await self?.close() }
    }

    func close() async {
        if let closing { return await closing.value }
        isClosing = true
        isReady = false
        preparation?.cancel()
        let pendingPreparation = preparation
        rotationTask?.cancel()
        audioTask?.cancel()
        let task = Task { @MainActor [self] in
            await pendingPreparation?.value
            releaseInput()
            input?.finish()
            await inputWorker?.value
            if !keysAwaitingRelease.isEmpty {
                do {
                    let releases = keysAwaitingRelease.map { SimulatorHIDEvent.keyboard(direction: .up, keyCode: $0) }
                    try await backend.send(.composite(releases))
                    keysAwaitingRelease.removeAll()
                } catch {
                    errorMessage = "Unable to release simulator keyboard input: \(error.localizedDescription)"
                }
            }
            await backend.close()
            hasInputConnection = false
            frames?.cancel()
            geometryUpdates?.cancel()
            await frames?.value
            await geometryUpdates?.value
            replaceSurface(nil)
            input = nil
            preparation = nil
            inputWorker = nil
            frames = nil
            geometryUpdates = nil
            rotationTask = nil
            isRotating = false
            if let lease { SimulatorOperationRegistry.shared.release(lease) }
            lease = nil
        }
        closing = task
        await task.value
    }
}

/// All synchronous framework setup, device properties and ROC/XPC getters live here,
/// never on MainActor. Bootstrap/SimulatorSet never leave this actor. Upstream's
/// Sendable HID/framebuffer handles own their own locks/actors and callback queues.
private actor EmbeddedSimulatorBackend {
    struct Connection: Sendable {
        let geometry: SimulatorDisplayGeometry?
        let legacyScale: CGFloat?
        let legacyRotation: Int
        let surfaces: AsyncStream<IOSurface?>
    }

    private var bootstrap: SimulatorControlBootstrap?
    private var simulator: Simulator?
    private var framebuffer: Framebuffer?
    private var attachment: FramebufferAttachment?
    private var hid: SimulatorHIDSession?
    private var framePump: Task<Void, Never>?

    func open(deviceID: UUID) async throws -> Connection {
        let control = try SimulatorControlBootstrap.withConfiguration(
            SimulatorControlConfiguration(deviceSetPath: nil, logger: nil)
        )
        bootstrap = control
        guard let target = control.set.simulator(withUDID: deviceID.uuidString), target.state == .booted else {
            throw ToolchainError.message("The simulator is no longer booted. Refresh the device list and try again.")
        }
        simulator = target
        let geometry = try await target.displays.swiftDeckGeometry()
        var scale: CGFloat?
        var rotation = 0
        if geometry == nil {
            guard let reportedScale = target.screenInfo?.scale, reportedScale > 0 else {
                throw ToolchainError.message("The simulator did not report its screen scale.")
            }
            scale = CGFloat(reportedScale)
            rotation = try SimulatorDisplayCommands.swiftDeckLegacyInterfaceRotation(on: target)
        }
        try Task.checkCancellation()
        let display = try target.framebuffer.connect()
        framebuffer = display
        let attachment = try display.attach()
        self.attachment = attachment
        // Every item includes the current surface, so coalescing frames cannot lose a
        // surface swap. Drain the upstream lossless callback stream without XPC/UI work.
        let (surfaces, continuation) = AsyncStream.makeStream(
            of: IOSurface?.self, bufferingPolicy: .bufferingNewest(1)
        )
        let pump = Task.detached(priority: .userInitiated) {
            var current = attachment.initialSurface
            continuation.yield(current)
            for await event in attachment.events {
                if Task.isCancelled { break }
                if case .surfaceChanged(let surface) = event { current = surface }
                continuation.yield(current)
            }
            continuation.finish()
        }
        framePump = pump
        continuation.onTermination = { _ in pump.cancel() }
        if geometry == nil {
            hid = try await SimulatorHIDSession.swiftDeckOpenLegacyMainDisplay(on: target)
        } else {
            hid = try await SimulatorHIDSession.open(target)
        }
        return Connection(geometry: geometry, legacyScale: scale, legacyRotation: rotation, surfaces: surfaces)
    }

    func isBooted() -> Bool { simulator?.state == .booted }

    private func target() throws -> Simulator {
        guard let simulator else { throw ToolchainError.message("The simulator display connection is closed.") }
        return simulator
    }

    func geometry() async throws -> SimulatorDisplayGeometry? {
        try await target().displays.swiftDeckGeometry()
    }

    func legacyInterfaceRotation() throws -> Int {
        try SimulatorDisplayCommands.swiftDeckLegacyInterfaceRotation(on: target())
    }

    func orientation() async throws -> SimulatorDeviceOrientation {
        try await target().orientation.current()
    }

    func setOrientation(_ orientation: SimulatorDeviceOrientation) async throws {
        try await target().orientation.set(orientation)
    }

    func audioSettings() async throws -> SimulatorAudioSettings {
        try await target().audio.settings()
    }

    func setRingerEnabled(_ enabled: Bool) async throws {
        try await target().audio.updateSettings(SimulatorAudioSettingsUpdate(ringerEnabled: enabled))
    }

    func send(_ event: SimulatorHIDEvent) async throws {
        guard let hid else { throw ToolchainError.message("The simulator input connection is closed.") }
        try await hid.hid.send(event: event, logger: target().logger)
    }

    func send(_ events: AsyncThrowingStream<SimulatorHIDEvent, Error>) async throws {
        guard let hid else { throw ToolchainError.message("The simulator input connection is closed.") }
        try await hid.hid.send(events: events, logger: target().logger)
    }

    func close() async {
        await hid?.close()
        hid = nil
        attachment?.cancel()
        framePump?.cancel()
        await framePump?.value
        framePump = nil
        attachment = nil
        framebuffer = nil
        simulator = nil
        bootstrap = nil
    }
}

/// Bounded, single-consumer gesture channel. Keep the initial down, all discrete
/// events and the final up. Only superseded adjacent motion samples coalesce when
/// the transport falls behind; no tasks or unbounded streams are created per input.
@MainActor
private final class SimulatorGestureBuffer {
    private struct Sample {
        let event: SimulatorHIDEvent
        let isMotion: Bool
    }
    private var storage = [Sample?](repeating: nil, count: 64)
    private var head = 0
    private var count = 0
    private var finished = false
    private var failure: Error?
    private var waiter: CheckedContinuation<SimulatorHIDEvent?, Error>?

    var events: AsyncThrowingStream<SimulatorHIDEvent, Error> {
        AsyncThrowingStream(unfolding: { try await self.next() })
    }

    func yield(_ event: SimulatorHIDEvent, isMotion: Bool = false) {
        guard !finished else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: event)
            return
        }
        let last = (head + count + storage.count - 1) % storage.count
        if isMotion, count >= 8, storage[last]?.isMotion == true {
            storage[last] = Sample(event: event, isMotion: true)
        } else if count < storage.count {
            storage[(head + count) % storage.count] = Sample(event: event, isMotion: isMotion)
            count += 1
        } else {
            // Throw through upstream HID's contact cleanup, then session.close()
            // explicitly releases keys. Discrete input is never silently discarded.
            failure = ToolchainError.message("Simulator input could not keep up. Input was released safely.")
            finish()
        }
    }

    func finish() {
        finished = true
        if let waiter {
            self.waiter = nil
            if let failure { waiter.resume(throwing: failure) }
            else { waiter.resume(returning: nil) }
        }
    }

    private func next() async throws -> SimulatorHIDEvent? {
        if let failure { throw failure }
        if count > 0 {
            let sample = storage[head]
            storage[head] = nil
            head = (head + 1) % storage.count
            count -= 1
            return sample?.event
        }
        if finished { return nil }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
}
