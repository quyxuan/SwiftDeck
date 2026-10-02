import Foundation
import Testing
@testable import SwiftDeck

@Suite("Local Xcode project metadata")
@MainActor
struct XcodeProjectMetadataTests {
    @Test func importsUnresolvedPackagesWithoutRunningTheBuildGraph() async throws {
        let files = try MetadataFiles()
        defer { files.remove() }
        let project = try files.project("Offline", configurations: ["Development", "Production"])
        // OpenStep syntax, as written by Xcode, including a package that is unavailable offline.
        try files.text("""
        // !$*UTF8*$!
        { archiveVersion = 1; objectVersion = 77; rootObject = ROOT; objects = {
          ROOT = { isa = PBXProject; targets = (APP,); buildConfigurationList = CONFIGS;
                   packageReferences = (PACKAGE,); };
          APP = { isa = PBXNativeTarget; name = "Offline App"; buildConfigurationList = CONFIGS;
                  productType = "com.apple.product-type.application"; };
          CONFIGS = { isa = XCConfigurationList; buildConfigurations = (DEV, PROD,); };
          DEV = { isa = XCBuildConfiguration; name = Development; buildSettings = {}; };
          PROD = { isa = XCBuildConfiguration; name = Production; buildSettings = {}; };
          PACKAGE = { isa = XCRemoteSwiftPackageReference; repositoryURL = "https://unavailable.invalid/package.git";
                      requirement = { kind = upToNextMajorVersion; minimumVersion = 1.0.0; }; };
        }; }
        """, at: project.appendingPathComponent("project.pbxproj"))

        let imported = try await XcodeBuildService().discoverProject(at: project)
        #expect(imported.name == "Offline")
        #expect(imported.schemes == ["Offline App"])
        #expect(imported.configurations == ["Development", "Production"])
        #expect(imported.configuration == "Development")
        #expect(imported.path == project.path)
    }

    @Test func discoversNativeAggregateAndLegacyTargetsAndSuppressesOnlyManagedTargets() async throws {
        let files = try MetadataFiles()
        defer { files.remove() }
        let project = try files.project("Kinds", targets: [
            ("APP", "App", "PBXNativeTarget", "com.apple.product-type.application"),
            ("FRAMEWORK", "Framework", "PBXNativeTarget", "com.apple.product-type.framework"),
            ("AGGREGATE", "All", "PBXAggregateTarget", ""),
            ("LEGACY", "Make", "PBXLegacyTarget", "")
        ])
        try files.management(in: project, suppress: ["APP": true, "FRAMEWORK": false])
        let metadata = try await XcodeProjectMetadata.read(at: project)
        #expect(metadata.schemes == ["All", "Framework", "Make"])
    }

    @Test func preservesHiddenSharedAndCurrentUserSchemesWithoutImportingOtherUsers() async throws {
        let files = try MetadataFiles()
        defer { files.remove() }
        let project = try files.project("App")
        try files.scheme("CI", in: project)
        try files.scheme("Local", in: project, user: NSUserName())
        try files.scheme("Other User", in: project, user: "unrelated-user")
        try files.management(in: project, suppress: ["APP": true], hidden: "CI")
        let metadata = try await XcodeProjectMetadata.read(at: project)
        #expect(metadata.schemes == ["CI", "Local"])
    }

    @Test func avoidsExtraTestSchemeWhenTestsAlreadyBelongToAnExplicitScheme() async throws {
        let files = try MetadataFiles()
        defer { files.remove() }
        let project = try files.project("App", targets: [
            ("APP", "App", "PBXNativeTarget", "com.apple.product-type.application"),
            ("TESTS", "UnitTests", "PBXNativeTarget", "com.apple.product-type.bundle.unit-test"),
            ("UITESTS", "UITests", "PBXNativeTarget", "com.apple.product-type.bundle.ui-testing")
        ])
        try files.scheme("Custom", in: project, references: [("APP", "container:App.xcodeproj"), ("TESTS", "container:App.xcodeproj")])
        let metadata = try await XcodeProjectMetadata.read(at: project)
        #expect(metadata.schemes == ["App", "Custom", "UITests"])
    }

    @Test func respectsDisabledAutocreationAndUserSettingsPrecedence() async throws {
        let files = try MetadataFiles()
        defer { files.remove() }
        let project = try files.project("App")
        try files.scheme("Stored", in: project)
        let workspace = project.appendingPathComponent("project.xcworkspace")
        try files.plist(["IDEWorkspaceSharedSettings_AutocreateContextsIfNeeded": false],
                        at: workspace.appendingPathComponent("xcshareddata/WorkspaceSettings.xcsettings"))
        #expect(try await XcodeProjectMetadata.read(at: project).schemes == ["Stored"])
        try files.plist(["IDEWorkspaceSharedSettings_AutocreateContextsIfNeeded": true],
                        at: workspace.appendingPathComponent("xcuserdata/\(NSUserName()).xcuserdatad/WorkspaceSettings.xcsettings"))
        #expect(try await XcodeProjectMetadata.read(at: project).schemes == ["App", "Stored"])
    }

    @Test func resolvesNestedWorkspaceGroupsAbsoluteMembersAndSchemeOnlyProjects() async throws {
        let files = try MetadataFiles()
        defer { files.remove() }
        let first = try files.project("Modules/First", configurations: ["Debug", "Staging"])
        let second = try files.project("Second", configurations: ["Release", "Enterprise"])
        _ = try files.project("SchemeOnly", configurations: ["Profile"])
        let workspace = try files.workspace("Suite", contents: """
        <Group location="group:Modules"><Group name="Logical Group">
          <FileRef location="group:First.xcodeproj"/>
          <FileRef location="container:Second.xcodeproj"/>
        </Group></Group>
        <FileRef location="absolute:\(second.path)"/>
        <FileRef location="group:Suite.xcworkspace"/>
        """)
        try files.scheme("Workspace CI", in: workspace, references: [("APP", "container:SchemeOnly.xcodeproj")])
        try files.scheme("Shared", in: first)
        try files.scheme("Shared", in: second)
        let metadata = try await XcodeProjectMetadata.read(at: workspace)
        #expect(metadata.schemes == ["First", "SchemeOnly", "Second", "Shared", "Workspace CI"])
        #expect(metadata.configurations == ["Debug", "Enterprise", "Profile", "Release", "Staging"])
    }

    @Test func appliesWorkspaceSuppressionAfterDiscoveringMemberTargets() async throws {
        let files = try MetadataFiles()
        defer { files.remove() }
        _ = try files.project("App")
        let workspace = try files.workspace("Suite", contents: "<FileRef location=\"group:App.xcodeproj\"/>")
        try files.scheme("Workspace CI", in: workspace)
        try files.management(in: workspace, suppress: ["APP": true])
        #expect(try await XcodeProjectMetadata.read(at: workspace).schemes == ["Workspace CI"])
    }

    @Test func usesSelectedWorkspaceSettingsRatherThanEachMembersPrivateWorkspace() async throws {
        let files = try MetadataFiles()
        defer { files.remove() }
        let project = try files.project("App")
        try files.scheme("Stored", in: project)
        try files.plist(["IDEWorkspaceSharedSettings_AutocreateContextsIfNeeded": false],
                        at: project.appendingPathComponent("project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings"))
        let workspace = try files.workspace("Suite", contents: "<FileRef location=\"group:App.xcodeproj\"/>")
        #expect(try await XcodeProjectMetadata.read(at: workspace).schemes == ["App", "Stored"])
        try files.plist(["IDEWorkspaceSharedSettings_AutocreateContextsIfNeeded": false],
                        at: workspace.appendingPathComponent("xcshareddata/WorkspaceSettings.xcsettings"))
        #expect(try await XcodeProjectMetadata.read(at: workspace).schemes == ["Stored"])
    }

    @Test func followsReferencedSubprojectsWithoutLoopingOrLosingTheirConfigurations() async throws {
        let files = try MetadataFiles()
        defer { files.remove() }
        let project = try files.project("Parent", references: ["Modules/Child.xcodeproj"])
        _ = try files.project("Modules/Child", configurations: ["AdHoc"], references: ["../Parent.xcodeproj"])
        let metadata = try await XcodeProjectMetadata.read(at: project)
        #expect(metadata.schemes == ["Child", "Parent"])
        #expect(metadata.configurations == ["AdHoc", "Debug", "Release"])
    }

    @Test func readsEmbeddedWorkspaceSelfReferenceAndItsStoredSchemes() async throws {
        let files = try MetadataFiles()
        defer { files.remove() }
        let project = try files.project("App")
        let workspace = project.appendingPathComponent("project.xcworkspace")
        try files.text("<Workspace><FileRef location=\"self:\"/></Workspace>",
                       at: workspace.appendingPathComponent("contents.xcworkspacedata"))
        try files.scheme("Embedded", in: workspace, references: [("APP", "container:App.xcodeproj")])
        #expect(try await XcodeProjectMetadata.read(at: workspace).schemes == ["App", "Embedded"])
    }

    @Test(arguments: ["Package", "Package/Package.swift"])
    func delegatesStandalonePackageSchemesToXcode(memberPath: String) async throws {
        let files = try MetadataFiles()
        defer { files.remove() }
        try files.text("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Package", products: [], targets: [])
        """, at: files.root.appendingPathComponent("Package/Package.swift"))
        let workspace = try files.workspace("Suite", contents: "<FileRef location=\"group:\(memberPath)\"/>")
        await #expect(throws: XcodeGeneratedMetadataRequired.standalonePackage) {
            try await XcodeProjectMetadata.read(at: workspace)
        }
    }

    @Test(arguments: ["com.apple.product-type.application.watchapp", "com.apple.product-type.watchkit-extension"])
    func delegatesOnlyUnstoredLegacyWatchAutocreation(productType: String) async throws {
        let files = try MetadataFiles()
        defer { files.remove() }
        let project = try files.project("Watch", targets: [("WATCH", "Watch", "PBXNativeTarget", productType)])
        await #expect(throws: XcodeGeneratedMetadataRequired.legacyWatchTarget) {
            try await XcodeProjectMetadata.read(at: project)
        }
        try files.scheme("Stored Watch", in: project)
        try files.management(in: project, suppress: ["WATCH": true])
        #expect(try await XcodeProjectMetadata.read(at: project).schemes == ["Stored Watch"])
    }

    @Test func malformedMemberStillFailsLocallyWhenAnotherMemberRequiresGeneratedSchemes() async throws {
        let files = try MetadataFiles()
        defer { files.remove() }
        try files.text("// swift-tools-version: 6.0", at: files.root.appendingPathComponent("Package/Package.swift"))
        let project = try files.project("Broken")
        try files.text("{ objects = {}; }", at: project.appendingPathComponent("project.pbxproj"))
        let workspace = try files.workspace("Suite", contents: """
        <FileRef location="group:Package"/><FileRef location="group:Broken.xcodeproj"/>
        """)
        await #expect(throws: ToolchainError.self) { try await XcodeProjectMetadata.read(at: workspace) }
    }

    @Test func missingPackageManifestFailsLocallyRatherThanDelegating() async throws {
        let files = try MetadataFiles()
        defer { files.remove() }
        let workspace = try files.workspace("Suite", contents: "<FileRef location=\"group:Missing/Package.swift\"/>")
        await #expect(throws: ToolchainError.self) { try await XcodeProjectMetadata.read(at: workspace) }
    }

    @Test func reportsMissingWorkspaceMembersInsteadOfReturningPartialMetadata() async throws {
        let files = try MetadataFiles()
        defer { files.remove() }
        _ = try files.project("App")
        let workspace = try files.workspace("Suite", contents: """
        <FileRef location="group:App.xcodeproj"/><FileRef location="group:Missing.xcodeproj"/>
        """)
        await #expect(throws: ToolchainError.self) { try await XcodeProjectMetadata.read(at: workspace) }
    }

    @Test func rejectsMalformedProjectAndSchemeMetadata() async throws {
        let files = try MetadataFiles()
        defer { files.remove() }
        let project = try files.project("App")
        try files.text("<NotAScheme/>", at: project.appendingPathComponent("xcshareddata/xcschemes/Broken.xcscheme"))
        await #expect(throws: ToolchainError.self) { try await XcodeProjectMetadata.read(at: project) }
        try files.text("{ objects = {}; }", at: project.appendingPathComponent("project.pbxproj"))
        await #expect(throws: ToolchainError.self) { try await XcodeProjectMetadata.read(at: project) }
    }
}

@MainActor
private struct MetadataFiles {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftDeck-Metadata-\(UUID().uuidString)")
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func project(_ name: String, configurations: [String] = ["Debug", "Release"],
                 targets: [(String, String, String, String)]? = nil, references: [String] = []) throws -> URL {
        let url = root.appendingPathComponent(name + ".xcodeproj")
        let targets = targets ?? [("APP", url.deletingPathExtension().lastPathComponent,
                                   "PBXNativeTarget", "com.apple.product-type.application")]
        let configurationIDs = configurations.indices.map { "CONFIG\($0)" }
        var objects: [String: Any] = [
            "ROOT": ["isa": "PBXProject", "targets": targets.map { $0.0 }, "buildConfigurationList": "CONFIGS"],
            "CONFIGS": ["isa": "XCConfigurationList", "buildConfigurations": configurationIDs]
        ]
        for (id, name, kind, type) in targets {
            objects[id] = ["isa": kind, "name": name, "productType": type, "buildConfigurationList": "CONFIGS"]
        }
        for (index, name) in configurations.enumerated() {
            objects[configurationIDs[index]] = ["isa": "XCBuildConfiguration", "name": name, "buildSettings": [:]] as [String: Any]
        }
        if !references.isEmpty {
            let ids = references.indices.map { "REF\($0)" }
            objects["ROOT"] = ["isa": "PBXProject", "targets": targets.map { $0.0 },
                               "buildConfigurationList": "CONFIGS", "mainGroup": "GROUP",
                               "projectReferences": ids.map { ["ProjectRef": $0] }] as [String: Any]
            objects["GROUP"] = ["isa": "PBXGroup", "sourceTree": "<group>", "children": ids]
            for (index, path) in references.enumerated() {
                objects[ids[index]] = ["isa": "PBXFileReference", "path": path, "sourceTree": "<group>"]
            }
        }
        try plist(["rootObject": "ROOT", "objects": objects], at: url.appendingPathComponent("project.pbxproj"))
        return url
    }

    func workspace(_ name: String, contents: String) throws -> URL {
        let url = root.appendingPathComponent(name + ".xcworkspace")
        try text("<Workspace version=\"1.0\">\(contents)</Workspace>", at: url.appendingPathComponent("contents.xcworkspacedata"))
        return url
    }

    func scheme(_ name: String, in container: URL, user: String? = nil, references: [(String, String)] = []) throws {
        let directory = user.map { "xcuserdata/\($0).xcuserdatad/xcschemes" } ?? "xcshareddata/xcschemes"
        let buildables = references.map {
            "<BuildableReference BlueprintIdentifier=\"\($0.0)\" ReferencedContainer=\"\($0.1)\"/>"
        }.joined()
        try text("<Scheme version=\"1.3\"><TestAction>\(buildables)</TestAction></Scheme>",
                 at: container.appendingPathComponent(directory).appendingPathComponent(name + ".xcscheme"))
    }

    func management(in container: URL, suppress: [String: Bool], hidden: String? = nil) throws {
        var data: [String: Any] = ["SuppressBuildableAutocreation": suppress.mapValues { ["primary": $0] }]
        if let hidden { data["SchemeUserState"] = [hidden + ".xcscheme_^#shared#^_": ["isShown": false]] }
        try plist(data, at: container.appendingPathComponent("xcuserdata/\(NSUserName()).xcuserdatad/xcschemes/xcschememanagement.plist"))
    }

    func text(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func plist(_ value: [String: Any], at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
