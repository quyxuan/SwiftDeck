import Combine
import Foundation
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    @Published var appearance: AppAppearance {
        didSet {
            guard appearance != oldValue else { return }
            defaults.set(appearance.rawValue, forKey: Key.appearance)
        }
    }

    @Published var automaticallyExpandBuildLog: Bool {
        didSet {
            guard automaticallyExpandBuildLog != oldValue else { return }
            defaults.set(automaticallyExpandBuildLog, forKey: Key.automaticallyExpandBuildLog)
        }
    }

    @Published var followBuildOutput: Bool {
        didSet {
            guard followBuildOutput != oldValue else { return }
            defaults.set(followBuildOutput, forKey: Key.followBuildOutput)
        }
    }

    private enum Key {
        static let appearance = "settings.appearance"
        static let automaticallyExpandBuildLog = "settings.automaticallyExpandBuildLog"
        static let followBuildOutput = "settings.followBuildOutput"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Key.appearance)
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
        automaticallyExpandBuildLog = defaults.object(forKey: Key.automaticallyExpandBuildLog) as? Bool ?? true
        followBuildOutput = defaults.object(forKey: Key.followBuildOutput) as? Bool ?? true
    }
}
