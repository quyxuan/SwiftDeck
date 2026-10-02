import AppKit
import SwiftUI

struct ShortcutsSettingsView: View {
    @ObservedObject var store: ShortcutStore
    @State private var recordingAction: ShortcutAction?
    @State private var errors: [ShortcutAction: String] = [:]

    var body: some View {
        Form {
            Section {
                Text("Click a shortcut, then press a new combination including Command (⌘). Press Escape or Cancel to keep the current shortcut.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(ShortcutAction.allCases) { action in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(action.title)
                            Spacer()
                            if recordingAction == action {
                                Button("Cancel") { recordingAction = nil }
                                    .controlSize(.small)
                            }
                            ShortcutRecorder(
                                actionTitle: action.title,
                                binding: store[action],
                                isRecording: recordingAction == action,
                                onRecordingChange: { recording in
                                    if recording {
                                        errors[action] = nil
                                        recordingAction = action
                                    } else if recordingAction == action {
                                        recordingAction = nil
                                    }
                                },
                                onCapture: { binding in
                                    let error = store.set(binding, for: action)
                                    errors[action] = error
                                    return error == nil
                                },
                                onUnsupportedKey: {
                                    errors[action] = "Choose a letter, number, punctuation key, or arrow key with Command (⌘)."
                                }
                            )
                            .frame(width: 160, height: 26)
                        }
                        if let error = errors[action] {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .accessibilityLabel("Shortcut error: \(error)")
                        }
                    }
                }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("Standard macOS shortcuts are reserved. Each app shortcut must be unique.")
            }
            Section {
                Button("Restore Defaults") {
                    recordingAction = nil
                    errors.removeAll()
                    store.restoreDefaults()
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { recordingAction = nil }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let actionTitle: String
    let binding: ShortcutBinding
    let isRecording: Bool
    let onRecordingChange: (Bool) -> Void
    let onCapture: (ShortcutBinding) -> Bool
    let onUnsupportedKey: () -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.target = button
        button.action = #selector(ShortcutRecorderButton.toggleRecording)
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.onRecordingChange = onRecordingChange
        button.onCapture = onCapture
        button.onUnsupportedKey = onUnsupportedKey
        button.shortcutTitle = binding.displayName
        button.setAccessibilityLabel("\(actionTitle) shortcut")
        button.setAccessibilityHelp("Activate to record a shortcut. Escape cancels recording.")
        button.setRecording(isRecording, notify: false)
        button.updateTitle()
    }

    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: ()) {
        button.setRecording(false, notify: false)
    }
}

/// A responder-local control, not a key-event monitor: ordinary app and simulator
/// input is untouched unless this particular button is actively recording.
private final class ShortcutRecorderButton: NSButton {
    var shortcutTitle = ""
    var onRecordingChange: ((Bool) -> Void)?
    var onCapture: ((ShortcutBinding) -> Bool)?
    var onUnsupportedKey: (() -> Void)?
    private var isRecording = false
    private var windowObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { true }

    @objc func toggleRecording() {
        if isRecording {
            setRecording(false)
        } else if window?.makeFirstResponder(self) == true {
            setRecording(true)
        }
    }

    func setRecording(_ recording: Bool, notify: Bool = true) {
        guard recording != isRecording else { return }
        isRecording = recording
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
        if recording, let window {
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setRecording(false) }
            }
        }
        updateTitle()
        if notify { onRecordingChange?(recording) }
    }

    func updateTitle() {
        title = isRecording ? "Press shortcut…" : shortcutTitle
        setAccessibilityValue(isRecording ? "Recording shortcut" : shortcutTitle)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setRecording(false) }
        return resigned
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.isKeyWindow == true, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        capture(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        capture(event)
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == 53 {
            setRecording(false)
            return
        }
        if event.keyCode == 48 {
            setRecording(false)
            if event.modifierFlags.contains(.shift) {
                window?.selectPreviousKeyView(self)
            } else {
                window?.selectNextKeyView(self)
            }
            return
        }
        guard !event.isARepeat else { return }
        guard let binding = ShortcutBinding(event: event) else {
            onUnsupportedKey?()
            return
        }
        if onCapture?(binding) == true { setRecording(false) }
    }
}
