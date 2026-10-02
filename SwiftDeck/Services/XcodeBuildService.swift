import Foundation
import CryptoKit

@MainActor
struct XcodeBuildService: BuildServiceProtocol {
    private let runner = ProcessRunner()
    private let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")

    func discoverProject(at url: URL) async throws -> ProjectModel {
        try Task.checkCancellation()
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        _ = try projectSelector(url)
        let metadata: XcodeProjectMetadata
        do {
            metadata = try await XcodeProjectMetadata.read(at: url)
        } catch is XcodeGeneratedMetadataRequired {
            metadata = try await generatedMetadata(at: url)
        }
        let schemes = metadata.schemes
        guard let scheme = schemes.first else {
            throw ToolchainError.message("No schemes are available in \(url.lastPathComponent). Create or share an application scheme in the project first.")
        }
        let names = metadata.configurations
        guard let configuration = names.first(where: { $0 == "Debug" }) ?? names.first else {
            throw ToolchainError.message("No build configurations were discovered in \(url.lastPathComponent).")
        }
        try Task.checkCancellation()
        return ProjectModel(
            id: stableID(for: url.path), name: metadata.name,
            path: url.path, schemes: schemes, scheme: scheme,
            configurations: names, configuration: configuration
        )
    }

    /// Package workspace members and legacy watch schemes require Xcode's generated build graph.
    /// Keep this path authoritative; all ordinary declarations avoid package resolution entirely.
    private func generatedMetadata(at url: URL) async throws -> XcodeProjectMetadata {
        let selector = try projectSelector(url)
        let listing: ProjectListing = try await json(["xcodebuild"] + selector + ["-list", "-json"])
        guard let metadata = listing.project ?? listing.workspace else {
            throw ToolchainError.message("xcodebuild did not return project or workspace metadata for \(url.path).")
        }
        let schemes = Array(Set(metadata.schemes ?? [])).sorted()
        var configurations = Set(metadata.configurations ?? [])
        if url.pathExtension == "xcworkspace" {
            var inspectedProjects = Set<String>()
            for scheme in schemes {
                try Task.checkCancellation()
                let settings: [TargetSettings] = try await json(
                    ["xcodebuild"] + selector + ["-scheme", scheme, "-showBuildSettings", "-json"]
                )
                for target in settings {
                    if let path = target.buildSettings["PROJECT_FILE_PATH"], inspectedProjects.insert(path).inserted {
                        let member: ProjectListing = try await json(["xcodebuild", "-project", path, "-list", "-json"])
                        configurations.formUnion(member.project?.configurations ?? [])
                    }
                    if let configuration = target.buildSettings["CONFIGURATION"] {
                        configurations.insert(configuration)
                    }
                }
            }
        }
        return XcodeProjectMetadata(
            name: metadata.name ?? url.deletingPathExtension().lastPathComponent,
            schemes: schemes, configurations: configurations.sorted()
        )
    }

    func build(
        _ context: BuildContext,
        onOutput: @escaping @MainActor (String) -> Void
    ) async throws {
        let arguments = try buildArguments(context)
        _ = try await runner.run(executable: xcrun, arguments: ["xcodebuild"] + arguments + ["build"], onOutput: onOutput)
        try Task.checkCancellation()
    }

    func builtApplication(_ context: BuildContext) async throws -> BuildArtifact {
        let arguments = try buildArguments(context)
        let targets: [TargetSettings] = try await json(["xcodebuild"] + arguments + ["-showBuildSettings", "-json"])
        let applications = targets.filter {
            $0.buildSettings["PRODUCT_TYPE"] == "com.apple.product-type.application" &&
            $0.buildSettings["PLATFORM_NAME"] == "iphonesimulator"
        }
        guard applications.count == 1, let settings = applications.first?.buildSettings,
              let directory = settings["TARGET_BUILD_DIR"], let product = settings["FULL_PRODUCT_NAME"] else {
            throw ToolchainError.message("The scheme must produce exactly one iOS Simulator application. Found \(applications.count) application targets; select the main app scheme.")
        }
        let appURL = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(product, isDirectory: true)
        let infoURL = appURL.appendingPathComponent("Info.plist")
        guard FileManager.default.fileExists(atPath: appURL.path),
              let data = try? Data(contentsOf: infoURL),
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty,
              let platforms = info["CFBundleSupportedPlatforms"] as? [String], platforms.contains("iPhoneSimulator"),
              let executable = info["CFBundleExecutable"] as? String,
              FileManager.default.isExecutableFile(atPath: appURL.appendingPathComponent(executable).path) else {
            throw ToolchainError.message("The build succeeded but a valid iOS Simulator application was not found at \(appURL.path).")
        }
        try Task.checkCancellation()
        return BuildArtifact(appURL: appURL, bundleIdentifier: bundleID)
    }

    func clean(_ context: BuildContext, onOutput: @escaping @MainActor (String) -> Void) async throws {
        _ = try await runner.run(
            executable: xcrun, arguments: ["xcodebuild"] + buildArguments(context) + ["clean"], onOutput: onOutput
        )
        try Task.checkCancellation()
    }

    private func buildArguments(_ context: BuildContext) throws -> [String] {
        try Task.checkCancellation()
        guard !context.scheme.isEmpty, !context.configuration.isEmpty else {
            throw ToolchainError.message("Select a discovered scheme and configuration before building.")
        }
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let derivedData = root.appendingPathComponent("SwiftDeck/DerivedData/\(context.projectID.uuidString)", isDirectory: true)
        return try projectSelector(URL(fileURLWithPath: context.projectPath)) + [
            "-scheme", context.scheme, "-configuration", context.configuration,
            "-sdk", "iphonesimulator", "-destination",
            context.simulatorID.map { "platform=iOS Simulator,id=\($0.uuidString)" } ?? "generic/platform=iOS Simulator",
            "-derivedDataPath", derivedData.path, "CODE_SIGNING_ALLOWED=NO"
        ]
    }

    private func projectSelector(_ url: URL) throws -> [String] {
        var isDirectory: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              ["xcodeproj", "xcworkspace"].contains(url.pathExtension) else {
            throw ToolchainError.message("Choose an existing .xcodeproj or .xcworkspace package, not a source folder.")
        }
        return [url.pathExtension == "xcworkspace" ? "-workspace" : "-project", url.path]
    }

    private func json<T: Decodable & Sendable>(_ arguments: [String]) async throws -> T {
        let result = try await runner.run(executable: xcrun, arguments: arguments)
        try Task.checkCancellation()
        guard !result.outputTruncated else {
            throw ToolchainError.message("xcodebuild metadata exceeded the 8 MiB capture limit. Reduce the selected workspace or scheme scope.")
        }
        do {
            return try await Self.decodeMetadata(result.stdout)
        } catch {
            throw ToolchainError.message("Could not read xcodebuild metadata: \(error.localizedDescription)\n\(result.stderr.suffix(4_096))\n\(result.stdout.suffix(4_096))")
        }
    }

    @concurrent
    private static func decodeMetadata<T: Decodable & Sendable>(_ json: String) async throws -> T {
        try Task.checkCancellation()
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func stableID(for path: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(path.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    nonisolated private struct ProjectListing: Decodable, Sendable {
        let project: ListingMetadata?
        let workspace: ListingMetadata?
    }

    nonisolated private struct ListingMetadata: Decodable, Sendable {
        let name: String?
        let schemes: [String]?
        let configurations: [String]?
    }

    nonisolated private struct TargetSettings: Decodable, Sendable {
        let buildSettings: [String: String]
    }
}
