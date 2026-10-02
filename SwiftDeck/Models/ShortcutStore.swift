import AppKit
import Combine
import SwiftUI

/// One catalog supplies the Settings labels, default bindings, and command menu bindings.
nonisolated enum ShortcutAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case openProject, switchProject, quickBuild
    case selectProject1, selectProject2, selectProject3, selectProject4, selectProject5
    case selectProject6, selectProject7, selectProject8, selectProject9
    case previousProject, nextProject, build, run, stop, clean

    var id: String { rawValue }

    static let projectSelections: [Self] = [
        .selectProject1, .selectProject2, .selectProject3, .selectProject4, .selectProject5,
        .selectProject6, .selectProject7, .selectProject8, .selectProject9
    ]

    var title: String {
        switch self {
        case .openProject: "Open Project…"
        case .switchProject: "Switch Project…"
        case .quickBuild: "Quick Build…"
        case .previousProject: "Previous Project"
        case .nextProject: "Next Project"
        case .build: "Build"
        case .run: "Run"
        case .stop: "Stop"
        case .clean: "Clean Build Folder"
        default: "Select Project \(Self.projectSelections.firstIndex(of: self)! + 1)"
        }
    }

    var defaultBinding: ShortcutBinding {
        switch self {
        case .openProject: ShortcutBinding(key: "o")
        case .switchProject: ShortcutBinding(key: "p")
        case .quickBuild: ShortcutBinding(key: "b", modifiers: [.command, .shift])
        case .previousProject: ShortcutBinding(key: "left", modifiers: [.command, .option])
        case .nextProject: ShortcutBinding(key: "right", modifiers: [.command, .option])
        case .build: ShortcutBinding(key: "b")
        case .run: ShortcutBinding(key: "r")
        case .stop: ShortcutBinding(key: ".")
        case .clean: ShortcutBinding(key: "k", modifiers: [.command, .shift])
        default: ShortcutBinding(key: String(Self.projectSelections.firstIndex(of: self)! + 1))
        }
    }
}

nonisolated struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt
    static let command = Self(rawValue: 1 << 0)
    static let shift = Self(rawValue: 1 << 1)
    static let option = Self(rawValue: 1 << 2)
    static let control = Self(rawValue: 1 << 3)
    static let supported: Self = [.command, .shift, .option, .control]

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if contains(.command) { result.insert(.command) }
        if contains(.shift) { result.insert(.shift) }
        if contains(.option) { result.insert(.option) }
        if contains(.control) { result.insert(.control) }
        return result
    }
}

nonisolated struct ShortcutBinding: Codable, Hashable, Sendable {
    let key: String
    let modifiers: ShortcutModifiers

    init(key: String, modifiers: ShortcutModifiers = .command) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    @MainActor
    init?(event: NSEvent) {
        let key: String
        switch event.keyCode {
        case 123: key = "left"
        case 124: key = "right"
        case 125: key = "down"
        case 126: key = "up"
        default:
            guard let characters = event.characters(byApplyingModifiers: []), !characters.isEmpty else {
                return nil
            }
            key = characters
        }
        var modifiers: ShortcutModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        self.init(key: key, modifiers: modifiers)
    }

    var keyboardShortcut: KeyboardShortcut {
        let equivalent: KeyEquivalent
        switch key {
        case "left": equivalent = .leftArrow
        case "right": equivalent = .rightArrow
        case "up": equivalent = .upArrow
        case "down": equivalent = .downArrow
        default: equivalent = KeyEquivalent(Character(key))
        }
        return KeyboardShortcut(equivalent, modifiers: modifiers.eventModifiers)
    }

    var displayName: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        switch key {
        case "left": result += "←"
        case "right": result += "→"
        case "up": result += "↑"
        case "down": result += "↓"
        default: result += key.uppercased()
        }
        return result
    }

    var validationError: String? {
        guard modifiers.contains(.command) else {
            return "Include the Command (⌘) key so typing and dialog controls keep working."
        }
        guard modifiers.subtracting(.supported).isEmpty else {
            return "This modifier combination is not supported."
        }
        guard key == key.lowercased(),
              ["left", "right", "up", "down"].contains(key)
                || (key.unicodeScalars.count == 1 && key.unicodeScalars.allSatisfy({ (33...126).contains($0.value) })) else {
            return "Choose a letter, number, punctuation key, or arrow key with Command (⌘)."
        }
        // Keep standard app, editing, text-navigation, and window shortcuts available.
        if ["c", "x", "v", "a", "z", "q", "w", "h", "m", ",", "`"].contains(key)
            || (modifiers == .command && ["n", "s", "f", "g", "e", "t"].contains(key))
            || (modifiers == [.command, .shift] && ["s", "g", "t", "/"].contains(key))
            || (modifiers == [.command, .control] && ["f", "s"].contains(key))
            || ((modifiers == .command || modifiers == [.command, .shift])
                && ["left", "right", "up", "down"].contains(key))
            || (modifiers == [.command, .option] && key == "s") {
            return "\(displayName) is reserved for macOS or standard app controls. Choose another shortcut."
        }
        return nil
    }
}

@MainActor
final class ShortcutStore: ObservableObject {
    static let persistenceKey = "keyboardShortcuts.v1"
    @Published private(set) var bindings: [ShortcutAction: ShortcutBinding]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let original = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultBinding) })
        guard let data = defaults.data(forKey: Self.persistenceKey),
              let saved = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) else {
            bindings = original
            return
        }
        var restored = original
        for (name, binding) in saved {
            if let action = ShortcutAction(rawValue: name) { restored[action] = binding }
        }
        // Restore atomically: a partial recovery could give a fallback default to an action
        // whose shortcut was intentionally reassigned to another action in the saved snapshot.
        if restored.values.allSatisfy({ $0.validationError == nil }),
           Set(restored.values).count == restored.count {
            bindings = restored
        } else {
            bindings = original
        }
    }

    subscript(action: ShortcutAction) -> ShortcutBinding {
        bindings[action] ?? action.defaultBinding
    }

    /// Returns a user-facing rejection without changing either the active or saved binding.
    @discardableResult
    func set(_ binding: ShortcutBinding, for action: ShortcutAction) -> String? {
        if let error = binding.validationError { return error }
        if let conflict = ShortcutAction.allCases.first(where: { $0 != action && self[$0] == binding }) {
            return "\(binding.displayName) is already used by \(conflict.title). Choose another shortcut."
        }
        bindings[action] = binding
        persist()
        return nil
    }

    func restoreDefaults() {
        bindings = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultBinding) })
        defaults.removeObject(forKey: Self.persistenceKey)
    }

    private func persist() {
        let saved = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: Self.persistenceKey)
        }
    }
}
