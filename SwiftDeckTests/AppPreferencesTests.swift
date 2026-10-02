import Foundation
import Testing
@testable import SwiftDeck

@Suite("App preferences")
@MainActor
struct AppPreferencesTests {
    @Test func disabledBuildLogPreferencesSurviveReload() throws {
        let suiteName = "SwiftDeck-AppPreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)

        preferences.automaticallyExpandBuildLog = false
        preferences.followBuildOutput = false

        let restored = AppPreferences(defaults: defaults)
        #expect(!restored.automaticallyExpandBuildLog)
        #expect(!restored.followBuildOutput)

        restored.automaticallyExpandBuildLog = true
        let updated = AppPreferences(defaults: defaults)
        #expect(updated.automaticallyExpandBuildLog)
        #expect(!updated.followBuildOutput)
    }

    @Test func invalidSavedAppearanceFallsBackAndCanBeReplaced() throws {
        let suiteName = "SwiftDeck-AppPreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("unsupported-appearance", forKey: "settings.appearance")

        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.appearance == .system)
        #expect(preferences.appearance.colorScheme == nil)

        preferences.appearance = .dark
        #expect(AppPreferences(defaults: defaults).appearance == .dark)
        preferences.appearance = .system
        #expect(AppPreferences(defaults: defaults).appearance == .system)
    }
}
