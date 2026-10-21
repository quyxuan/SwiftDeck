import Foundation
import Testing
@testable import SwiftDeck

@Suite("Editable keyboard shortcuts")
@MainActor
struct ShortcutStoreTests {
    @Test func rebindPersistsAcrossInstancesAndRestoreClearsCustomizations() throws {
        let fixture = try ShortcutDefaults()
        defer { fixture.remove() }
        let store = ShortcutStore(defaults: fixture.defaults)
        let custom = ShortcutBinding(key: "j", modifiers: [.command, .option])

        #expect(store.set(custom, for: .build) == nil)
        #expect(store[.build] == custom)
        let restarted = ShortcutStore(defaults: fixture.defaults)
        #expect(restarted[.build] == custom)
        #expect(restarted[.run] == ShortcutAction.run.defaultBinding)
        #expect(restarted[.screenshot] == ShortcutBinding(key: "s"))
        #expect(restarted[.copyScreenshot] == ShortcutBinding(key: "i", modifiers: [.command, .shift]))

        restarted.restoreDefaults()
        let restored = ShortcutStore(defaults: fixture.defaults)
        for action in ShortcutAction.allCases {
            #expect(restored[action] == action.defaultBinding)
        }
    }

    @Test func rejectedConflictPreservesPreviousAndSavedBinding() throws {
        let fixture = try ShortcutDefaults()
        defer { fixture.remove() }
        let store = ShortcutStore(defaults: fixture.defaults)
        let custom = ShortcutBinding(key: "j", modifiers: [.command, .option])
        #expect(store.set(custom, for: .build) == nil)

        let error = store.set(store[.run], for: .build)
        #expect(error?.contains(ShortcutAction.run.title) == true)
        #expect(store[.build] == custom)
        #expect(ShortcutStore(defaults: fixture.defaults)[.build] == custom)
        #expect(store.set(ShortcutBinding(key: "s"), for: .build)?.contains("Take Simulator Screenshot") == true)
        #expect(store.set(ShortcutBinding(key: "i", modifiers: [.command, .shift]), for: .build)?
            .contains("Copy Simulator Screenshot") == true)
        // An action may keep its own binding; this is not a conflict.
        #expect(store.set(custom, for: .build) == nil)
    }

    @Test(arguments: [
        ShortcutBinding(key: ","),
        ShortcutBinding(key: "q"),
        ShortcutBinding(key: "w", modifiers: [.command, .option]),
        ShortcutBinding(key: "v", modifiers: [.command, .option, .shift]),
        ShortcutBinding(key: "z", modifiers: [.command, .shift]),
        ShortcutBinding(key: "left", modifiers: [.command, .shift]),
        ShortcutBinding(key: "s", modifiers: [.command, .control]),
        ShortcutBinding(key: "j", modifiers: .shift),
        ShortcutBinding(key: "\r"),
        ShortcutBinding(key: "\u{1b}"),
        ShortcutBinding(key: "j", modifiers: ShortcutModifiers(rawValue: 1 | 16))
    ])
    func reservedOrInvalidInputsDoNotReplaceExistingBinding(binding: ShortcutBinding) throws {
        let fixture = try ShortcutDefaults()
        defer { fixture.remove() }
        let store = ShortcutStore(defaults: fixture.defaults)
        #expect(store.set(binding, for: .build) != nil)
        #expect(store[.build] == ShortcutAction.build.defaultBinding)
        #expect(ShortcutStore(defaults: fixture.defaults)[.build] == ShortcutAction.build.defaultBinding)
    }

    @Test func modifiersDistinguishBindingsAndReleasedShortcutCanBeReused() throws {
        let fixture = try ShortcutDefaults()
        defer { fixture.remove() }
        let store = ShortcutStore(defaults: fixture.defaults)
        #expect(store.set(ShortcutBinding(key: "b", modifiers: [.command, .option]), for: .run) == nil)
        #expect(store.set(ShortcutBinding(key: "j"), for: .build) == nil)
        #expect(store.set(ShortcutBinding(key: "b"), for: .stop) == nil)
        let restarted = ShortcutStore(defaults: fixture.defaults)
        #expect(restarted[.stop] == ShortcutBinding(key: "b"))
        #expect(restarted[.build] == ShortcutBinding(key: "j"))
        #expect(restarted[.run] == ShortcutBinding(key: "b", modifiers: [.command, .option]))
    }

    @Test(arguments: ["q", "r", "", "not json"])
    func corruptedOrConflictingSnapshotRestoresUsableDefaults(savedKey: String) throws {
        let fixture = try ShortcutDefaults()
        defer { fixture.remove() }
        let data = try savedKey == "not json"
            ? Data("not json".utf8)
            : JSONEncoder().encode(["build": ShortcutBinding(key: savedKey)])
        fixture.defaults.set(data, forKey: ShortcutStore.persistenceKey)
        let store = ShortcutStore(defaults: fixture.defaults)
        for action in ShortcutAction.allCases {
            #expect(store[action] == action.defaultBinding)
        }
        #expect(store.set(ShortcutBinding(key: "j"), for: .build) == nil)
        #expect(ShortcutStore(defaults: fixture.defaults)[.build] == ShortcutBinding(key: "j"))
    }

    @Test func partialSnapshotRetainsValidCustomizationAndDefaultsMissingActions() throws {
        let fixture = try ShortcutDefaults()
        defer { fixture.remove() }
        let custom = ShortcutBinding(key: "j", modifiers: [.command, .control])
        let data = try JSONEncoder().encode(["build": custom, "unknownFutureAction": custom])
        fixture.defaults.set(data, forKey: ShortcutStore.persistenceKey)
        let store = ShortcutStore(defaults: fixture.defaults)
        #expect(store[.build] == custom)
        #expect(store[.nextProject] == ShortcutAction.nextProject.defaultBinding)
    }
}

private struct ShortcutDefaults {
    let suite = "SwiftDeck-ShortcutTests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
    }
}
