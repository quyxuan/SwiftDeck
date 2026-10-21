import Foundation
import Testing
@testable import SwiftDeck

@Suite("App preferences")
@MainActor
struct AppPreferencesTests {
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
