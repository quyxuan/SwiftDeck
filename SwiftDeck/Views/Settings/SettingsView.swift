import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var shortcuts: ShortcutStore
    @ObservedObject var updater: AppUpdater

    var body: some View {
        TabView {
            AppearanceSettingsView(preferences: preferences)
                .tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }

            ShortcutsSettingsView(store: shortcuts)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            UpdateSettingsView(updater: updater)
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }

            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 640, idealWidth: 680, minHeight: 500, idealHeight: 540)
        .preferredColorScheme(preferences.appearance.colorScheme)
    }
}

private struct AppearanceSettingsView: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $preferences.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityHint("Changes the appearance of all SwiftDeck windows immediately.")
            } header: {
                Text("Window Appearance")
            } footer: {
                Text("System follows your macOS appearance, including automatic changes between light and dark. Your selection applies to all SwiftDeck windows.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettingsView: View {
    @State private var copyStatus: String?
    private let information = AppInformation(bundle: .main)
    private let releasesURL = URL(string: "https://github.com/quyxuan/SwiftDeck-Releases")!

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .accessibilityHidden(true)
                    Text(information.name)
                        .font(.title.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("Version \(information.version) (\(information.build))")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Build, run, and manage your local Xcode projects.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(spacing: 12) {
                        LabeledContent("macOS", value: information.operatingSystem)
                        Divider()
                        LabeledContent("Architecture", value: information.architecture)
                    }
                    .textSelection(.enabled)
                    .padding(8)
                }

                HStack(spacing: 12) {
                    Button("Copy Diagnostics", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        copyStatus = NSPasteboard.general.setString(information.diagnostics, forType: .string)
                            ? "Diagnostics copied to the clipboard."
                            : "Diagnostics could not be copied. Try again."
                    }
                    .help("Copy the app version, build, macOS version, and architecture. No project paths or build output are included.")
                    Link("GitHub Releases", destination: releasesURL)
                }

                if let copyStatus {
                    Text(copyStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(copyStatus)
                }
            }
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
            .padding(28)
        }
    }
}

private struct AppInformation {
    let name: String
    let version: String
    let build: String
    let identifier: String?
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString

    var architecture: String {
        #if arch(arm64)
        "arm64 (Apple silicon)"
        #elseif arch(x86_64)
        "x86_64 (Intel)"
        #else
        "Other"
        #endif
    }

    init(bundle: Bundle) {
        name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? bundle.bundleURL.deletingPathExtension().lastPathComponent
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unavailable"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unavailable"
        identifier = bundle.bundleIdentifier
    }

    var diagnostics: String {
        var lines = [
            "\(name) \(version) (\(build))",
            "macOS: \(operatingSystem)",
            "Architecture: \(architecture)"
        ]
        if let identifier { lines.append("Bundle identifier: \(identifier)") }
        return lines.joined(separator: "\n")
    }
}
