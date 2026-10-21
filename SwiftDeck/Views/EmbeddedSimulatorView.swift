import AppKit
import Combine
import CoreImage
import FBSimulatorControl
import ImageIO
import IOSurface
import MetalKit
@preconcurrency import QuartzCore
import SwiftUI

struct EmbeddedSimulatorView: View {
    @ObservedObject var model: DashboardViewModel
    @ObservedObject var session: EmbeddedSimulatorSession
    @State private var hasKeyboardFocus = false
    @State private var rendererError: String?
    @State private var inputResetID = 0
    @State private var confirmsShutdown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var displayError: String? { session.errorMessage ?? rendererError }
    private var status: String {
        if displayError != nil { return "Unavailable" }
        if session.isRotating { return "Rotating…" }
        return session.isReady ? "Connected" : "Connecting…"
    }
    private var keyboardHelp: String {
        let focus = hasKeyboardFocus
            ? "Keyboard connected. Click outside the display to return to SwiftDeck."
            : "Click the display to type. Drag or scroll to swipe."
        return "\(focus) Physical keyboard input only; host IME composition is not supported. ⌘A/C/V/X/Z go to the simulator while focused; SwiftDeck’s run, build, and stop shortcuts stay available."
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                toolbar(compact: geometry.size.width < 760)
            }
            .frame(height: 50)
            .background(Color(white: 0.04))
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            GeometryReader { geometry in
                deviceFrame(in: geometry.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(white: 0.145))
            .overlay(alignment: .top) {
                if let message = session.controlError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(message).font(.caption).textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button {
                            session.controlError = nil
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help("Dismiss simulator control error")
                        .accessibilityLabel("Dismiss simulator control error")
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12)))
                    .padding(12)
                    .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
            .animation(reduceMotion ? nil : DashboardMotion.content, value: session.controlError != nil)
            .clipped()
        }
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 420, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
        .confirmationDialog("Shut down \(session.device.name)?", isPresented: $confirmsShutdown, titleVisibility: .visible) {
            Button("Shut Down", role: .destructive) {
                guard model.embeddedSimulator?.device.id == session.device.id else { return }
                resetInput()
                model.shutdownEmbeddedSimulator()
            }
            .disabled(!model.canShutdownEmbeddedSimulator)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This shuts down the entire simulator and stops all apps running on it, including apps opened outside SwiftDeck. Disconnect instead to leave the simulator and its apps running.")
        }
        .onChange(of: session.device.id) { _, _ in
            rendererError = nil
            hasKeyboardFocus = false
            confirmsShutdown = false
            inputResetID += 1
        }
        .onDisappear { session.releaseInput() }
    }

    private func toolbar(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            Image(systemName: "iphone")
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityHidden(true)
            if compact {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.device.name).font(.system(size: 12, weight: .medium))
                    Text(status).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                        .contentTransition(.opacity)
                        .animation(reduceMotion ? nil : DashboardMotion.feedback, value: status)
                }
                .lineLimit(1)
                .help("\(session.device.name) · \(status)")
            } else {
                Text(session.device.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(status).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : DashboardMotion.feedback, value: status)
            }
            Spacer(minLength: 0)
            deviceMenu(compact: compact)
            Button {
                resetInput()
                session.rotateClockwise()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                    if !compact { Text("Rotate") }
                }
                .frame(minWidth: compact ? 14 : 0, minHeight: 18)
            }
            .disabled(!session.isReady || session.isRotating || displayError != nil)
            .help("Rotate the physical device clockwise. Apps may lock their interface orientation.")
            .accessibilityLabel("Rotate simulator clockwise")
            Button {
                session.pressHardwareButton(.volumeDown)
            } label: {
                Image(systemName: "speaker.minus").frame(width: 14, height: 18)
            }
            .disabled(!session.isReady || session.isRotating || displayError != nil)
            .help("Turn down Simulator volume")
            .accessibilityLabel("Simulator volume down")
            Button {
                session.pressHardwareButton(.volumeUp)
            } label: {
                Image(systemName: "speaker.plus").frame(width: 14, height: 18)
            }
            .disabled(!session.isReady || session.isRotating || displayError != nil)
            .help("Turn up Simulator volume")
            .accessibilityLabel("Simulator volume up")
            Button {
                session.toggleSilent()
            } label: {
                Image(systemName: session.isSilent == true ? "bell.slash.fill" : "bell")
                    .frame(width: 14, height: 18)
            }
            .disabled(!session.isReady || session.isRotating || session.isChangingSilent || displayError != nil)
            .help("Toggle Simulator Silent Mode")
            .accessibilityLabel("Toggle Simulator Silent Mode")
            .accessibilityValue(session.isSilent.map { $0 ? "On" : "Off" } ?? "Unknown")
            Button {
                resetInput()
                session.pressHome()
            } label: {
                Image(systemName: "house").frame(width: 14, height: 18)
            }
            .disabled(!session.isReady || session.isRotating || displayError != nil)
            .help("Go to the simulator Home screen")
            .accessibilityLabel("Simulator Home")
            Button {
                resetInput()
                session.pressHardwareButton(.lock)
            } label: {
                Image(systemName: "power").frame(width: 14, height: 18)
            }
            .disabled(!session.isReady || session.isRotating || displayError != nil)
            .help("Press the Simulator power button to lock or wake the screen")
            .accessibilityLabel("Simulator power button")
            Menu {
                Button("Disconnect", systemImage: "rectangle.portrait.and.arrow.right") {
                    resetInput()
                    model.closeEmbeddedSimulator()
                }
                Divider()
                Button("Shut Down…", systemImage: "power", role: .destructive) {
                    resetInput()
                    confirmsShutdown = true
                }
                .disabled(!model.canShutdownEmbeddedSimulator)
                .help(model.canShutdownEmbeddedSimulator
                      ? "Shut down the simulator and stop all its apps"
                      : "Shutdown is unavailable while another operation uses this simulator")
            } label: {
                Image(systemName: "ellipsis").frame(width: 14, height: 18)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Disconnect the display or shut down the simulator")
            .accessibilityLabel("Simulator display options")
        }
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.92))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func deviceMenu(compact: Bool) -> some View {
        Menu {
            ForEach(model.simulators) { simulator in
                Button {
                    guard simulator.id != session.device.id else { return }
                    resetInput()
                    model.performSimulatorAction(.embed, on: simulator.id)
                } label: {
                    if simulator.id == session.device.id {
                        Label(simulator.name, systemImage: "checkmark")
                    } else {
                        Text(simulator.name)
                    }
                }
                .disabled(!model.canSimulatorAction(.embed, on: simulator.id))
            }
        } label: {
            HStack(spacing: 8) {
                Text(session.device.name).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .frame(width: compact ? 112 : 152, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.14)))
        .help("Choose an embedded simulator without changing the project’s run destination")
        .accessibilityLabel("Embedded simulator")
        .accessibilityValue(session.device.name)
    }

    private func deviceFrame(in available: CGSize) -> some View {
        let screen = session.displaySize
        let scale = min(max(1, available.width - 64) / (screen.width + 16),
                        max(1, available.height - 48) / (screen.height + 16))
        let size = CGSize(width: screen.width * scale, height: screen.height * scale)
        let bezel = max(4, min(9, min(size.width, size.height) * 0.022))
        let radius = min(size.width, size.height) * 0.115
        let outer = CGSize(width: size.width + bezel * 2, height: size.height + bezel * 2)
        return ZStack {
            sideButtons(size: outer)
                .fill(Color(white: 0.025))
                .accessibilityHidden(true)
            RoundedRectangle(cornerRadius: radius + bezel, style: .continuous)
                .fill(.black)
                .overlay {
                    RoundedRectangle(cornerRadius: radius + bezel, style: .continuous)
                        .strokeBorder(.white.opacity(0.09), lineWidth: 1)
                }
            ZStack {
                EmbeddedSimulatorDisplay(
                    session: session,
                    inputResetID: inputResetID,
                    cornerRadius: radius,
                    onFocusChange: { focused in hasKeyboardFocus = focused },
                    onError: { rendererError = $0 }
                )
                .transaction { $0.animation = nil }
                if let message = displayError {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").font(.title2)
                        Text("Simulator display unavailable").font(.headline)
                        Text(message).font(.callout).textSelection(.enabled)
                    }
                    .multilineTextAlignment(.center)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .transition(.opacity)
                } else if !session.isReady {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Connecting to simulator…").font(.callout)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : DashboardMotion.content, value: session.isReady)
            .animation(reduceMotion ? nil : DashboardMotion.content, value: displayError != nil)
            .foregroundStyle(.white)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .help(keyboardHelp)
        }
        .frame(width: outer.width, height: outer.height)
    }

    private func sideButtons(size: CGSize) -> Path {
        let landscape = size.width > size.height
        let length = landscape ? size.width : size.height
        var path = Path()
        for (position, fraction, opposite) in [(0.16, 0.04, false), (0.24, 0.075, false),
                                             (0.34, 0.075, false), (0.25, 0.09, true)] {
            let rect = landscape
                ? CGRect(x: length * position, y: opposite ? size.height - 1 : -3,
                         width: length * fraction, height: 4)
                : CGRect(x: opposite ? size.width - 1 : -3, y: length * position,
                         width: 4, height: length * fraction)
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: 2, height: 2))
        }
        return path
    }

    private func resetInput() {
        session.releaseInput()
        inputResetID += 1
        hasKeyboardFocus = false
    }
}

private struct EmbeddedSimulatorDisplay: NSViewRepresentable {
    let session: EmbeddedSimulatorSession
    let inputResetID: Int
    let cornerRadius: CGFloat
    let onFocusChange: (Bool) -> Void
    let onError: (String) -> Void

    func makeNSView(context: Context) -> SimulatorMetalView {
        SimulatorMetalView(session: session, onFocusChange: onFocusChange, onError: onError)
    }

    func updateNSView(_ view: SimulatorMetalView, context: Context) {
        view.update(session: session, inputResetID: inputResetID, cornerRadius: cornerRadius)
    }

    static func dismantleNSView(_ view: SimulatorMetalView, coordinator: ()) {
        view.detach()
    }
}

/// AppKit geometry/input stay on MainActor; drawable acquisition, CI encoding and
/// GPU completion belong to the renderer actor. Guest callbacks invalidate frames.
@MainActor
private final class SimulatorMetalView: MTKView, MTKViewDelegate {
    private var session: EmbeddedSimulatorSession
    private let onFocusChange: (Bool) -> Void
    private var renderer: SimulatorFrameRenderer?
    private var frameSubscription: AnyCancellable?
    private var frameIsDirty = true
    private var renderInFlight = false
    private var renderTask: Task<Void, Never>?
    private let onError: (String) -> Void
    private var reportedFocus = false
    private var pendingFocus: Bool?
    private var focusDeliveryScheduled = false
    private var cachedDrawableSize = CGSize.zero
    private var displayFrame = CGRect.zero
    private var shortcutMonitor: Any?
    private var heldKeys: Set<UInt32> = []
    private var heldModifiers: Set<UInt32> = []
    private var pointerIsDown = false
    private var lastTouch = CGPoint.zero
    private var wheelIsDown = false
    private var wheelEndTimer: Timer?
    private var inputResetID = 0
    private var screenCornerRadius: CGFloat = 0

    init(session: EmbeddedSimulatorSession, onFocusChange: @escaping (Bool) -> Void,
         onError: @escaping (String) -> Void) {
        self.session = session
        self.onFocusChange = onFocusChange
        self.onError = onError
        let metalDevice = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: metalDevice)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = true
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        autoResizeDrawable = true
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        delegate = self
        if let metalDevice {
            renderer = SimulatorFrameRenderer(device: metalDevice)
        } else {
            DispatchQueue.main.async { onError("A Metal device and command queue are required to display this simulator.") }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Interactive simulator display for \(session.device.name)")
        setAccessibilityHelp("Click to focus the physical keyboard. Drag or scroll to swipe. Click outside to release input. ⌘A/C/V/X/Z go to the simulator; SwiftDeck’s run, build, and stop shortcuts stay available. Host input-method composition is not supported.")
        observeFrames()
    }

    required init(coder: NSCoder) {
        fatalError("SimulatorMetalView must be initialized with an embedded session")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var inputIsFocused: Bool {
        session.isReady && !session.isRotating && renderer != nil &&
            window?.firstResponder === self && window?.isKeyWindow == true && NSApp.isActive
    }

    func update(session: EmbeddedSimulatorSession, inputResetID: Int, cornerRadius: CGFloat) {
        screenCornerRadius = cornerRadius
        layer?.cornerRadius = cornerRadius
        if self.inputResetID != inputResetID {
            releaseInput()
            self.inputResetID = inputResetID
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        }
        if self.session !== session {
            releaseInput()
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
            self.session = session
            observeFrames()
            frameIsDirty = true
            setAccessibilityLabel("Interactive simulator display for \(session.device.name)")
        }
        if !session.isReady || session.isRotating { releaseInput() }
        if session.isReady, frameIsDirty { requestFrame() }
        else if !session.isReady { isPaused = true }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        releaseInput()
        removeEventObservers()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            isPaused = true
            return
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowLostFocus),
                                               name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowLostFocus),
                                               name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                                               name: NSWindow.didDeminiaturizeNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                                               name: NSWindow.didMiniaturizeNotification, object: window)
        // Clicks outside the screen return keyboard input to the host. Only guest
        // editing equivalents are consumed before the host menu handles them.
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type != .keyDown {
                    if self.window?.firstResponder === self,
                       event.window !== self.window ||
                        !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                        self.releaseInput()
                        self.window?.makeFirstResponder(nil)
                    }
                    return false
                }
                guard self.inputIsFocused, event.window === self.window,
                      event.modifierFlags.contains(.command), Self.guestEditKeys.contains(event.keyCode) else {
                    return false
                }
                self.sendKeyDown(event)
                return true
            }
            return handled ? nil : event
        }
        update(session: session, inputResetID: inputResetID, cornerRadius: screenCornerRadius)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { reportFocus(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { releaseInput() }
        return accepted
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size {
            releaseInput()
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        }
        super.setFrameSize(newSize)
        requestFrame()
    }

    @objc private func windowLostFocus(_ notification: Notification) {
        releaseInput()
    }

    @objc private func visibilityChanged(_ notification: Notification) {
        if isDisplayVisible { requestFrame() }
        else {
            isPaused = true
            releaseInput()
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        isPaused = true
        releaseInput()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        requestFrame()
    }

    private var isDisplayVisible: Bool {
        guard let window else { return false }
        return !isHiddenOrHasHiddenAncestor && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private func observeFrames() {
        frameSubscription = session.frameAvailable.sink { [weak self] in
            self?.requestFrame()
        }
    }

    private func requestFrame() {
        frameIsDirty = true
        // MTK's display link retains its 60 Hz active cadence. It stops completely
        // after the dirty frame, rather than rendering the same IOSurface forever.
        if !renderInFlight, isDisplayVisible, session.isReady, renderer != nil { isPaused = false }
    }

    private func reportFocus(_ focused: Bool) {
        guard focused != (pendingFocus ?? reportedFocus) else { return }
        pendingFocus = focused
        guard !focusDeliveryScheduled else { return }
        focusDeliveryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusDeliveryScheduled = false
            let value = self.pendingFocus
            self.pendingFocus = nil
            guard let value, value != self.reportedFocus else { return }
            self.reportedFocus = value
            self.onFocusChange(value)
        }
    }

    private func removeEventObservers() {
        NotificationCenter.default.removeObserver(self)
        if let shortcutMonitor {
            NSEvent.removeMonitor(shortcutMonitor)
            self.shortcutMonitor = nil
        }
    }

    func detach() {
        releaseInput()
        removeEventObservers()
        isPaused = true
        delegate = nil
        frameSubscription = nil
        renderTask?.cancel()
        renderer = nil
    }

    private func releaseInput() {
        wheelEndTimer?.invalidate()
        wheelEndTimer = nil
        pointerIsDown = false
        wheelIsDown = false
        heldKeys.removeAll(keepingCapacity: true)
        heldModifiers.removeAll(keepingCapacity: true)
        session.releaseInput()
        reportFocus(false)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if cachedDrawableSize != .zero && size != cachedDrawableSize {
            releaseInput()
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        }
        cachedDrawableSize = .zero
        requestFrame()
    }

    func draw(in view: MTKView) {
        // No semaphore waits or drawable acquisition on the AppKit thread. One
        // submitted frame bounds GPU/encoding work; callbacks retain one dirty bit.
        guard isDisplayVisible, session.isReady, let renderer,
              let surface = session.surface, let metalLayer = layer as? CAMetalLayer,
              drawableSize.width > 0, drawableSize.height > 0 else {
            isPaused = true
            return
        }
        guard !renderInFlight else { return }
        guard frameIsDirty else {
            isPaused = true
            return
        }
        frameIsDirty = false
        renderInFlight = true
        let rotation = session.rotation
        let renderingSession = session
        updateDisplayFrame(surface: surface)
        surface.incrementUseCount()
        renderTask = Task { [weak self] in
            let result = await renderer.render(surface: surface, rotation: rotation, layer: metalLayer)
            surface.decrementUseCount()
            guard let self else { return }
            self.renderInFlight = false
            self.renderTask = nil
            guard !Task.isCancelled, self.session === renderingSession else {
                if self.renderer != nil { self.requestFrame() }
                return
            }
            switch result {
            case .presented: break
            case .unavailable: self.frameIsDirty = true
            case .failed(let message):
                self.renderer = nil
                self.isPaused = true
                self.onError(message)
            }
            if self.frameIsDirty { self.requestFrame() }
        }
    }

    private func updateDisplayFrame(surface: IOSurface) {
        let rotated = session.rotation == 90 || session.rotation == 270
        let width = CGFloat(rotated ? surface.height : surface.width)
        let height = CGFloat(rotated ? surface.width : surface.height)
        guard width > 0, height > 0 else { return }
        let scale = min(bounds.width / width, bounds.height / height)
        let size = CGSize(width: width * scale, height: height * scale)
        displayFrame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height)
        cachedDrawableSize = drawableSize
    }

    private func touchPoint(for event: NSEvent, clamp: Bool) -> CGPoint? {
        guard let surface = session.surface, session.pointSize.width > 0, session.pointSize.height > 0 else { return nil }
        updateDisplayFrame(surface: surface)
        guard displayFrame.width > 0, displayFrame.height > 0 else { return nil }
        let location = convert(event.locationInWindow, from: nil)
        guard clamp || displayFrame.contains(location) else { return nil }
        // pointSize and HID are display-relative; HID performs inverse rotation itself.
        return clampedTouch(CGPoint(x: (location.x - displayFrame.minX) / displayFrame.width * session.pointSize.width,
                                    y: (displayFrame.maxY - location.y) / displayFrame.height * session.pointSize.height))
    }

    private func clampedTouch(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), max(0, session.pointSize.width - 1)),
                y: min(max(point.y, 0), max(0, session.pointSize.height - 1)))
    }

    private func sendTouch(_ point: CGPoint, down: Bool) {
        lastTouch = point
        session.sendTouch(down: down, x: Double(point.x), y: Double(point.y))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard inputIsFocused, let point = touchPoint(for: event, clamp: false) else { return }
        finishWheelGesture()
        pointerIsDown = true
        reportFocus(true)
        sendTouch(point, down: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard inputIsFocused, pointerIsDown, let point = touchPoint(for: event, clamp: true) else { return }
        sendTouch(point, down: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard pointerIsDown else { return }
        pointerIsDown = false
        sendTouch(touchPoint(for: event, clamp: true) ?? lastTouch, down: false)
    }

    override func scrollWheel(with event: NSEvent) {
        guard inputIsFocused, !pointerIsDown else {
            super.scrollWheel(with: event)
            return
        }
        if event.phase.contains(.began) { finishWheelGesture() }
        let hasDelta = event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0
        if !wheelIsDown {
            guard hasDelta, let point = touchPoint(for: event, clamp: false) else { return }
            wheelIsDown = true
            sendTouch(point, down: true)
        }
        wheelEndTimer?.invalidate()
        wheelEndTimer = nil
        if hasDelta {
            let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            let point = clampedTouch(CGPoint(
                x: lastTouch.x + event.scrollingDeltaX * unit * session.pointSize.width / displayFrame.width,
                y: lastTouch.y - event.scrollingDeltaY * unit * session.pointSize.height / displayFrame.height
            ))
            sendTouch(point, down: true)
        }
        if event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
            finishWheelGesture()
        } else {
            // Keep trackpad momentum on the same contact; also terminate ordinary mouse-wheel bursts.
            let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishWheelGesture() }
            }
            wheelEndTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func finishWheelGesture() {
        wheelEndTimer?.invalidate()
        wheelEndTimer = nil
        guard wheelIsDown else { return }
        wheelIsDown = false
        sendTouch(lastTouch, down: false)
    }

    override func keyDown(with event: NSEvent) {
        guard inputIsFocused,
              !event.modifierFlags.contains(.command) || Self.guestEditKeys.contains(event.keyCode),
              Self.keyUsages[event.keyCode] != nil else {
            super.keyDown(with: event)
            return
        }
        sendKeyDown(event)
    }

    private func sendKeyDown(_ event: NSEvent) {
        guard let usage = Self.keyUsages[event.keyCode] else { return }
        synchronizeModifiers(event.modifierFlags)
        // The guest handles key repeat while a physical key remains down.
        if heldKeys.insert(usage).inserted { session.sendKey(usage: usage, down: true) }
        reportFocus(true)
    }

    override func keyUp(with event: NSEvent) {
        guard let usage = Self.keyUsages[event.keyCode], heldKeys.remove(usage) != nil else {
            super.keyUp(with: event)
            return
        }
        session.sendKey(usage: usage, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard inputIsFocused else {
            super.flagsChanged(with: event)
            return
        }
        if event.keyCode == 57 {
            session.sendKey(usage: 0x39, down: true)
            session.sendKey(usage: 0x39, down: false)
        }
        synchronizeModifiers(event.modifierFlags)
    }

    private func synchronizeModifiers(_ flags: NSEvent.ModifierFlags) {
        for modifier in Self.modifiers {
            let deviceFlags = flags.rawValue & modifier.pairMask
            let down = flags.contains(modifier.flag) &&
                (deviceFlags == 0 ? modifier.isLeft : deviceFlags & modifier.deviceMask != 0)
            if down {
                if heldModifiers.insert(modifier.usage).inserted {
                    session.sendKey(usage: modifier.usage, down: true)
                }
            } else if heldModifiers.remove(modifier.usage) != nil {
                session.sendKey(usage: modifier.usage, down: false)
            }
        }
    }

    private struct Modifier {
        let usage: UInt32
        let flag: NSEvent.ModifierFlags
        let deviceMask: UInt
        let pairMask: UInt
        let isLeft: Bool
    }

    // Device-dependent NX_* modifier masks distinguish simultaneous left/right keys.
    private static let modifiers: [Modifier] = [
        Modifier(usage: 0xE0, flag: .control, deviceMask: 0x1, pairMask: 0x2001, isLeft: true),
        Modifier(usage: 0xE4, flag: .control, deviceMask: 0x2000, pairMask: 0x2001, isLeft: false),
        Modifier(usage: 0xE1, flag: .shift, deviceMask: 0x2, pairMask: 0x6, isLeft: true),
        Modifier(usage: 0xE5, flag: .shift, deviceMask: 0x4, pairMask: 0x6, isLeft: false),
        Modifier(usage: 0xE2, flag: .option, deviceMask: 0x20, pairMask: 0x60, isLeft: true),
        Modifier(usage: 0xE6, flag: .option, deviceMask: 0x40, pairMask: 0x60, isLeft: false),
        Modifier(usage: 0xE3, flag: .command, deviceMask: 0x8, pairMask: 0x18, isLeft: true),
        Modifier(usage: 0xE7, flag: .command, deviceMask: 0x10, pairMask: 0x18, isLeft: false)
    ]

    private static let guestEditKeys: Set<UInt16> = [0, 8, 9, 7, 6] // A, C, V, X, Z

    // macOS physical virtual key codes → USB HID keyboard-page usages, independent of layout.
    private static let keyUsages: [UInt16: UInt32] = [
        0: 0x04, 1: 0x16, 2: 0x07, 3: 0x09, 4: 0x0B, 5: 0x0A, 6: 0x1D,
        7: 0x1B, 8: 0x06, 9: 0x19, 10: 0x64, 11: 0x05, 12: 0x14, 13: 0x1A,
        14: 0x08, 15: 0x15, 16: 0x1C, 17: 0x17, 18: 0x1E, 19: 0x1F,
        20: 0x20, 21: 0x21, 22: 0x23, 23: 0x22, 24: 0x2E, 25: 0x26,
        26: 0x24, 27: 0x2D, 28: 0x25, 29: 0x27, 30: 0x30, 31: 0x12,
        32: 0x18, 33: 0x2F, 34: 0x0C, 35: 0x13, 36: 0x28, 37: 0x0F,
        38: 0x0D, 39: 0x34, 40: 0x0E, 41: 0x33, 42: 0x31, 43: 0x36,
        44: 0x38, 45: 0x11, 46: 0x10, 47: 0x37, 48: 0x2B, 49: 0x2C,
        50: 0x35, 51: 0x2A, 53: 0x29,
        64: 0x6C, 65: 0x63, 67: 0x55, 69: 0x57, 71: 0x53, 75: 0x54,
        76: 0x58, 78: 0x56, 79: 0x6D, 80: 0x6E, 81: 0x67, 82: 0x62,
        83: 0x59, 84: 0x5A, 85: 0x5B, 86: 0x5C, 87: 0x5D, 88: 0x5E,
        89: 0x5F, 91: 0x60, 92: 0x61,
        96: 0x3E, 97: 0x3F, 98: 0x40, 99: 0x3C, 100: 0x41, 101: 0x42,
        103: 0x44, 105: 0x68, 106: 0x6B, 107: 0x69, 109: 0x43, 111: 0x45,
        113: 0x6A, 114: 0x49, 115: 0x4A, 116: 0x4B, 117: 0x4C, 118: 0x3D,
        119: 0x4D, 120: 0x3B, 121: 0x4E, 122: 0x3A, 123: 0x50, 124: 0x4F,
        125: 0x51, 126: 0x52
    ]
}

/// Only this actor touches CIContext, cached image graphs and the command queue.
/// CAMetalLayer supports background drawable acquisition; AppKit alone owns its
/// layout/visibility. A drawable's actual texture size wins if a resize overtook us.
private actor SimulatorFrameRenderer {
    enum Result: Sendable {
        case presented
        case unavailable
        case failed(String)
    }

    private let device: any MTLDevice
    private var context: CIContext?
    private var queue: (any MTLCommandQueue)?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
    private var cachedSurface: IOSurface?
    private var source: CIImage?
    private var image: CIImage?
    private var cachedRotation = -1
    private var cachedSize = CGSize.zero

    init(device: any MTLDevice) { self.device = device }

    func render(surface: IOSurface, rotation: Int, layer: CAMetalLayer) async -> Result {
        if context == nil {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
            queue = device.makeCommandQueue()
        }
        guard !Task.isCancelled else { return .unavailable }
        guard let context, let queue else {
            return .failed("A Metal command queue is required to display this simulator.")
        }
        // nextDrawable may wait for Core Animation. It cannot stall input/layout:
        // this actor runs off MainActor and the view admits at most one render.
        guard let drawable = layer.nextDrawable() else { return .unavailable }
        let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        guard size.width > 0, size.height > 0 else { return .unavailable }
        if cachedSurface !== surface {
            cachedSurface = surface
            source = CIImage(ioSurface: surface, options: [.colorSpace: colorSpace])
            image = nil
        }
        if image == nil || rotation != cachedRotation || size != cachedSize {
            let orientation: CGImagePropertyOrientation
            switch rotation {
            case 90: orientation = .right
            case 180: orientation = .down
            case 270: orientation = .left
            default: orientation = .up
            }
            guard let source else { return .unavailable }
            let oriented = source.oriented(orientation)
            let extent = oriented.extent
            guard extent.width > 0, extent.height > 0 else { return .unavailable }
            let scale = min(size.width / extent.width, size.height / extent.height)
            let transform = CGAffineTransform(
                a: scale, b: 0, c: 0, d: scale,
                tx: (size.width - extent.width * scale) / 2 - extent.minX * scale,
                ty: (size.height - extent.height * scale) / 2 - extent.minY * scale
            )
            image = oriented.transformed(by: transform).composited(over: black)
                .cropped(to: CGRect(origin: .zero, size: size))
            cachedRotation = rotation
            cachedSize = size
        }
        guard !Task.isCancelled, let image, let command = queue.makeCommandBuffer() else { return .unavailable }
        context.render(image, to: drawable.texture, commandBuffer: command,
                       bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        return await withCheckedContinuation { continuation in
            command.addCompletedHandler { buffer in
                if let error = buffer.error {
                    continuation.resume(returning: .failed("Simulator rendering failed: \(error.localizedDescription)"))
                } else {
                    continuation.resume(returning: .presented)
                }
            }
            command.present(drawable)
            command.commit()
        }
    }
}
