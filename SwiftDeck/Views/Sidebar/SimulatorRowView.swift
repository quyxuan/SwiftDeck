import AppKit
import SwiftUI

struct SimulatorRowView: View, Equatable {
    let model: DashboardViewModel
    let simulator: SimulatorModel
    let activity: String?
    let isDestination: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.simulator == rhs.simulator
            && lhs.activity == rhs.activity && lhs.isDestination == rhs.isDestination
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "iphone")
                    .font(.title3)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(simulator.name).lineLimit(1)
                    Text("\(simulator.runtime) · \(simulator.status.displayLabel)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let activity {
                        Text(activity)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 2)
                if isDestination {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Selected destination")
                }
                if activity != nil {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .focusable()
            .onKeyPress(.return) {
                model.selectSimulator(simulator.id)
                return .handled
            }
            .onKeyPress(.space) {
                model.selectSimulator(simulator.id)
                return .handled
            }
            // Independent recognizers let the first click select immediately;
            // a second click additionally opens the embedded display.
            .simultaneousGesture(TapGesture(count: 1).onEnded {
                model.selectSimulator(simulator.id)
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                model.performSimulatorAction(.embed, on: simulator.id)
            })
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.selectSimulator(simulator.id) }
            .overlay {
                SimulatorContextMenu(model: model, simulatorID: simulator.id)
                    .accessibilityHidden(true)
            }
            SimulatorActionButton(model: model, simulator: simulator)
                .frame(width: 20, height: 20)
                .help("Actions for \(simulator.name)")
                .accessibilityLabel("Actions for \(simulator.name)")
        }
        .padding(.vertical, 5)
    }

    private var statusColor: Color {
        switch simulator.status {
        case .booted: .green
        case .booting, .shuttingDown: .orange
        case .available, .unavailable: .secondary
        }
    }

}

// AppKit asks for menu contents only when opening the menu. Keeping the model
// as an action target (not an observed row dependency) avoids evaluating every
// device's permissions on every dashboard publication.
private final class SimulatorMenu: NSMenu {
    private let model: DashboardViewModel
    private let simulatorID: UUID
    private var actions: [SimulatorDeviceAction] = []

    init(model: DashboardViewModel, simulatorID: UUID) {
        self.model = model
        self.simulatorID = simulatorID
        super.init(title: "Simulator Actions")
        autoenablesItems = false
        add("Open in SwiftDeck", "rectangle.inset.filled", .embed)
        addItem(.separator())
        add("Boot & Open in Simulator (External)", "power", .bootAndOpen)
        add("Show in Simulator (External)", "iphone", .show)
        add("Shut Down…", "power.circle", .shutdown)
        add("Restart…", "arrow.clockwise", .restart)
        addItem(.separator())
        let destinationSymbol = model.selectedProject?.selectedSimulatorID == simulatorID
            ? "checkmark.circle.fill" : "checkmark.circle"
        add("Use as Destination", destinationSymbol, .useDestination)
        add("Run Selected Project Here", "play.fill", .runProject)
        add("Stop This Window’s App", "stop.fill", .stopApp)
        addItem(.separator())
        add("Save Screenshot…", "camera", .screenshot)
        add("Open URL…", "link", .openURL)
        add("Device Details…", "info.circle", .details)
        addItem(.separator())
        add("Copy UDID", "document.on.document", .copyUDID)
        add("Copy Device Name", "textformat", .copyName)
        add("Reveal Device Data", "folder", .revealData)
        addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh Simulators", action: #selector(refreshSimulators), keyEquivalent: "")
        refresh.target = self
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refresh.isEnabled = !model.isRefreshing
        addItem(refresh)
    }

    required init(coder: NSCoder) {
        fatalError("SimulatorMenu must be initialized with a dashboard and device")
    }

    private func add(_ title: String, _ symbol: String, _ action: SimulatorDeviceAction) {
        let item = NSMenuItem(title: title, action: #selector(performAction(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count
        actions.append(action)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.isEnabled = model.canSimulatorAction(action, on: simulatorID)
        addItem(item)
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        model.performSimulatorAction(actions[sender.tag], on: simulatorID)
    }

    @objc private func refreshSimulators() {
        Task { await model.refreshSimulators() }
    }
}

private struct SimulatorActionButton: NSViewRepresentable {
    let model: DashboardViewModel
    let simulator: SimulatorModel

    func makeNSView(context: Context) -> ActionButton {
        let button = ActionButton()
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.setAccessibilityRole(.popUpButton)
        button.target = button
        button.action = #selector(ActionButton.showActions)
        return button
    }

    func updateNSView(_ button: ActionButton, context: Context) {
        button.makeMenu = { SimulatorMenu(model: model, simulatorID: simulator.id) }
        button.toolTip = "Actions for \(simulator.name)"
        button.setAccessibilityLabel("Actions for \(simulator.name)")
    }

    final class ActionButton: NSButton {
        var makeMenu: (() -> NSMenu)?

        override func accessibilityPerformPress() -> Bool {
            // Menu tracking runs a nested event loop. Acknowledge the AX action
            // first so assistive clients do not time out waiting for dismissal.
            guard isEnabled, makeMenu != nil else { return false }
            DispatchQueue.main.async { [weak self] in self?.showActions() }
            return true
        }

        @objc func showActions() {
            guard let menu = makeMenu?() else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.minY), in: self)
        }
    }
}

private struct SimulatorContextMenu: NSViewRepresentable {
    let model: DashboardViewModel
    let simulatorID: UUID

    func makeNSView(context: Context) -> ContextView { ContextView() }

    func updateNSView(_ view: ContextView, context: Context) {
        view.makeMenu = { SimulatorMenu(model: model, simulatorID: simulatorID) }
    }

    final class ContextView: NSView {
        var makeMenu: (() -> NSMenu)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown
                    || event.type == .leftMouseDown && event.modifierFlags.contains(.control) else {
                return nil
            }
            return super.hitTest(point)
        }

        override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
    }
}
