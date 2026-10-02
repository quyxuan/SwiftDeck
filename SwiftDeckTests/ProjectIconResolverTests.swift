import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import SwiftDeck

@Suite("Selected application icons")
@MainActor
struct ProjectIconResolverTests {
    @Test func selectedSchemeUsesItsBuildableNotTheFirstApplication() async throws {
        let files = try IconFiles()
        defer { files.remove() }
        let project = try files.project("Apps", targets: ["First", "Selected"])
        try files.icon("First", color: .red)
        try files.icon("Selected", color: .blue)
        try files.scheme("Launch", in: project, references: [("Selected", "Apps.xcodeproj")])
        let data = await ProjectIconResolver.resolve(files.request(project, scheme: "Launch"))
        try expectColor(data, .blue)
    }

    @Test func workspaceLaunchBuildableWinsOverAnotherApplicationInBuildAction() async throws {
        let files = try IconFiles()
        defer { files.remove() }
        _ = try files.project("FirstProject", targets: ["First"])
        _ = try files.project("SecondProject", targets: ["Selected"])
        try files.icon("First", color: .red)
        try files.icon("Selected", color: .blue)
        let workspace = try files.workspace("Suite", members: ["FirstProject.xcodeproj", "SecondProject.xcodeproj"])
        try files.scheme("Workspace App", in: workspace,
                         references: [("First", "FirstProject.xcodeproj"), ("Selected", "SecondProject.xcodeproj")],
                         runnable: ("Selected", "SecondProject.xcodeproj"))
        try expectColor(await ProjectIconResolver.resolve(files.request(workspace, scheme: "Workspace App")), .blue)
    }

    @Test func configurationsAndInheritedXCConfigSelectDifferentArtwork() async throws {
        let files = try IconFiles()
        defer { files.remove() }
        let project = try files.project("App", targets: ["App"])
        try files.icon("App", name: "DebugIcon", color: .red)
        try files.icon("App", name: "ReleaseIcon", color: .blue)
        try files.text("ICON_STEM = Debug\n", at: files.root.appendingPathComponent("Base.xcconfig"))
        try files.text("#include \"Base.xcconfig\"\nASSETCATALOG_COMPILER_APPICON_NAME = $(ICON_STEM)Icon\nASSETCATALOG_COMPILER_APPICON_NAME[sdk=iphoneos*] = WrongIcon\nASSETCATALOG_COMPILER_APPICON_NAME[config=Release][sdk=iphonesimulator*] = ReleaseIcon\n",
                       at: files.root.appendingPathComponent("Icons.xcconfig"))
        try files.modify(project) { objects in
            objects["ICON_CONFIG"] = ["isa": "PBXFileReference", "path": "Icons.xcconfig", "sourceTree": "SOURCE_ROOT"]
            let children = objects["MAIN"]?["children"] as? [String] ?? []
            objects["MAIN"]?["children"] = children + ["ICON_CONFIG"]
            for configuration in ["Debug", "Release"] {
                objects["P_\(configuration)"]?["baseConfigurationReference"] = "ICON_CONFIG"
                objects["App_\(configuration)"]?["buildSettings"] = [
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "$(inherited)",
                    "PRODUCT_BUNDLE_IDENTIFIER": "test.App", "PRODUCT_NAME": "$(TARGET_NAME)"
                ]
            }
        }
        try expectColor(await ProjectIconResolver.resolve(files.request(project, scheme: "App")), .red)
        try expectColor(await ProjectIconResolver.resolve(files.request(project, scheme: "App", configuration: "Release")), .blue)
        #expect(await ProjectIconResolver.resolve(files.request(project, scheme: "App", configuration: "Absent")) == nil)
    }

    @Test func ranksEnoughPixelsBeforeOversizedOrUndersizedAndSkipsOtherAppearances() async throws {
        let files = try IconFiles()
        defer { files.remove() }
        let project = try files.project("App", targets: ["App"])
        try files.icon("App", images: [
            IconImage("small.png", size: 32, color: .red),
            IconImage("large.png", size: 1024, color: .red),
            IconImage("correct.png", size: 128, color: .blue),
            IconImage("dark.png", size: 96, color: .red, appearance: "dark"),
            IconImage("mac.png", size: 96, color: .red, idiom: "mac")
        ])
        let data = await ProjectIconResolver.resolve(files.request(project, scheme: "App"))
        try expectColor(data, .blue)
        let image = try decoded(data)
        #expect(image.width == 96 && image.height == 96)
    }

    @Test func absentAmbiguousAndNonApplicationSelectionsReturnNoIcon() async throws {
        let files = try IconFiles()
        defer { files.remove() }
        let project = try files.project("Apps", targets: ["First", "Second"])
        try files.icon("First", color: .red)
        try files.icon("Second", color: .blue)
        try files.scheme("Both", in: project, references: [("First", "Apps.xcodeproj"), ("Second", "Apps.xcodeproj")])
        #expect(await ProjectIconResolver.resolve(files.request(project, scheme: "Both")) == nil)
        #expect(await ProjectIconResolver.resolve(files.request(project, scheme: "Missing")) == nil)
        try files.modify(project) { $0["First"]?["productType"] = "com.apple.product-type.framework" }
        #expect(await ProjectIconResolver.resolve(files.request(project, scheme: "First")) == nil)
    }

    @Test func sameGeneratedSchemeNameAcrossWorkspaceIsAmbiguous() async throws {
        let files = try IconFiles()
        defer { files.remove() }
        _ = try files.project("One", targets: ["App"])
        _ = try files.project("Two", targets: ["App"])
        try files.icon("App", color: .red)
        let workspace = try files.workspace("Suite", members: ["One.xcodeproj", "Two.xcodeproj"])
        #expect(await ProjectIconResolver.resolve(files.request(workspace, scheme: "App")) == nil)
    }

    @Test func duplicateOwnedCatalogsAreAmbiguousAndUnownedCatalogIsIgnored() async throws {
        let files = try IconFiles()
        defer { files.remove() }
        let project = try files.project("App", targets: ["App"])
        try files.icon("App", color: .blue)
        try files.icon("Unowned", color: .red)
        try expectColor(await ProjectIconResolver.resolve(files.request(project, scheme: "App")), .blue)
        try files.icon("App", catalog: "Other", color: .red)
        try files.modify(project) { objects in
            objects["OTHER"] = ["isa": "PBXFileReference", "path": "App/Other.xcassets", "sourceTree": "SOURCE_ROOT"]
            objects["OTHER_BUILD"] = ["isa": "PBXBuildFile", "fileRef": "OTHER"]
            let children = objects["MAIN"]?["children"] as? [String] ?? []
            objects["MAIN"]?["children"] = children + ["OTHER"]
            objects["App_RESOURCES"]?["files"] = ["App_BUILD", "OTHER_BUILD"]
        }
        #expect(await ProjectIconResolver.resolve(files.request(project, scheme: "App")) == nil)
    }

    @Test func synchronizedMembershipExceptionsExcludeOtherTargetsArtwork() async throws {
        let files = try IconFiles()
        defer { files.remove() }
        let project = try files.project("App", targets: ["App"])
        try files.icon("App", color: .blue)
        try files.icon("App", catalog: "Excluded", color: .red)
        try files.modify(project) { objects in
            objects["SYNC"] = ["isa": "PBXFileSystemSynchronizedRootGroup", "path": "App", "sourceTree": "SOURCE_ROOT", "exceptions": ["EXCEPTIONS"]]
            objects["EXCEPTIONS"] = ["isa": "PBXFileSystemSynchronizedBuildFileExceptionSet", "target": "App", "membershipExceptions": ["Excluded.xcassets"]]
            objects["MAIN"]?["children"] = ["SYNC"]
            objects["App"]?["fileSystemSynchronizedGroups"] = ["SYNC"]
            objects["App_RESOURCES"]?["files"] = []
        }
        try expectColor(await ProjectIconResolver.resolve(files.request(project, scheme: "App")), .blue)
    }

    @Test func matchingBuiltIconWinsButWrongIdentityAndConfigurationDoNot() async throws {
        let files = try IconFiles()
        defer { files.remove() }
        let project = try files.project("App", targets: ["App"])
        try files.icon("App", color: .blue)
        let request = files.request(project, scheme: "App")
        let app = try files.builtApp(for: request, bundleID: "test.App", color: .red)
        try expectColor(await ProjectIconResolver.resolve(request), .red)
        try expectColor(await ProjectIconResolver.resolve(files.request(project, scheme: "App", configuration: "Release")), .blue)
        var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil) as! [String: Any]
        info["CFBundleIdentifier"] = "test.Other"
        try files.plist(info, at: app.appendingPathComponent("Info.plist"))
        try expectColor(await ProjectIconResolver.resolve(request), .blue)
        info["CFBundleIdentifier"] = "test.App"
        info["CFBundleIcons"] = ["CFBundlePrimaryIcon": ["CFBundleIconName": "OldIcon", "CFBundleIconFiles": ["CompiledIcon"]]]
        try files.plist(info, at: app.appendingPathComponent("Info.plist"))
        try expectColor(await ProjectIconResolver.resolve(request), .blue)
    }

    @Test func missingOrUnresolvedIconDoesNotBorrowAnotherAsset() async throws {
        let files = try IconFiles()
        defer { files.remove() }
        let project = try files.project("App", targets: ["App"])
        try files.icon("App", name: "Unrelated", color: .red)
        #expect(await ProjectIconResolver.resolve(files.request(project, scheme: "App")) == nil)
        try files.modify(project) { $0["App_Debug"]?["buildSettings"] = ["ASSETCATALOG_COMPILER_APPICON_NAME": "$(UNKNOWN)"] }
        #expect(await ProjectIconResolver.resolve(files.request(project, scheme: "App")) == nil)
    }

    @Test func excludedPathsAndNonResourcePhasesDoNotProvideIcons() async throws {
        let files = try IconFiles()
        defer { files.remove() }
        let project = try files.project("App", targets: ["App"])
        try files.icon("App", color: .blue)
        try files.modify(project) { objects in
            var settings = objects["App_Debug"]?["buildSettings"] as! [String: String]
            settings["EXCLUDED_SOURCE_FILE_NAMES"] = "App/*.xcassets"
            objects["App_Debug"]?["buildSettings"] = settings
        }
        #expect(await ProjectIconResolver.resolve(files.request(project, scheme: "App")) == nil)
        try files.modify(project) { objects in
            objects["App_RESOURCES"]?["isa"] = "PBXCopyFilesBuildPhase"
        }
        #expect(await ProjectIconResolver.resolve(files.request(project, scheme: "App", configuration: "Release")) == nil)
    }

    @Test func conflictingConditionalIconNamesDoNotChooseAnArbitraryVariant() async throws {
        let files = try IconFiles()
        defer { files.remove() }
        let project = try files.project("App", targets: ["App"])
        try files.icon("App", name: "FirstIcon", color: .red)
        try files.icon("App", name: "SecondIcon", color: .blue)
        try files.modify(project) { objects in
            objects["App_Debug"]?["buildSettings"] = [
                "ASSETCATALOG_COMPILER_APPICON_NAME[sdk=iphonesimulator*]": "FirstIcon",
                "ASSETCATALOG_COMPILER_APPICON_NAME[config=Debug]": "SecondIcon"
            ]
        }
        #expect(await ProjectIconResolver.resolve(files.request(project, scheme: "App")) == nil)
    }

    @Test func cancellationReturnsNoArtwork() async throws {
        let files = try IconFiles()
        defer { files.remove() }
        let project = try files.project("App", targets: ["App"])
        try files.icon("App", color: .blue)
        let request = files.request(project, scheme: "App")
        let task = Task { await ProjectIconResolver.resolve(request) }
        task.cancel()
        #expect(await task.value == nil)
    }

    private func decoded(_ data: Data?) throws -> CGImage {
        let data = try #require(data)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func expectColor(_ data: Data?, _ color: IconColor) throws {
        let image = try decoded(data)
        var pixel = [UInt8](repeating: 0, count: 4)
        let rendered = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        #expect(rendered)
        if color == .red { #expect(pixel[0] > 240 && pixel[2] < 15) }
        else { #expect(pixel[2] > 240 && pixel[0] < 15) }
        #expect(pixel[3] == 255)
    }
}

private enum IconColor { case red, blue }

private struct IconImage {
    let filename: String
    let size: Int
    let color: IconColor
    var idiom = "universal"
    var appearance: String?

    init(_ filename: String, size: Int, color: IconColor, idiom: String = "universal", appearance: String? = nil) {
        self.filename = filename; self.size = size; self.color = color; self.idiom = idiom; self.appearance = appearance
    }
}

@MainActor
private final class IconFiles {
    let root: URL
    let id = UUID()
    private var derivedData: URL?

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftDeck-IconTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        if let derivedData { try? FileManager.default.removeItem(at: derivedData) }
    }

    func request(_ project: URL, scheme: String, configuration: String = "Debug") -> ProjectIconRequest {
        ProjectIconRequest(projectID: id, projectPath: project.path, scheme: scheme, configuration: configuration)
    }

    func project(_ name: String, targets: [String]) throws -> URL {
        let url = root.appendingPathComponent(name + ".xcodeproj")
        var objects: [String: [String: Any]] = [
            "ROOT": ["isa": "PBXProject", "mainGroup": "MAIN", "targets": targets, "buildConfigurationList": "P_LIST"],
            "MAIN": ["isa": "PBXGroup", "sourceTree": "<group>", "children": targets.map { $0 + "_CATALOG" }],
            "P_LIST": ["isa": "XCConfigurationList", "buildConfigurations": ["P_Debug", "P_Release"]]
        ]
        for config in ["Debug", "Release"] {
            objects["P_\(config)"] = ["isa": "XCBuildConfiguration", "name": config, "buildSettings": [:] as [String: String]]
        }
        for target in targets {
            objects[target] = ["isa": "PBXNativeTarget", "name": target, "productType": "com.apple.product-type.application",
                               "buildConfigurationList": target + "_LIST", "buildPhases": [target + "_RESOURCES"]]
            objects[target + "_LIST"] = ["isa": "XCConfigurationList", "buildConfigurations": [target + "_Debug", target + "_Release"]]
            for config in ["Debug", "Release"] {
                objects[target + "_" + config] = ["isa": "XCBuildConfiguration", "name": config,
                    "buildSettings": ["ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "test.\(target)"]]
            }
            objects[target + "_CATALOG"] = ["isa": "PBXFileReference", "path": target + "/Assets.xcassets", "sourceTree": "SOURCE_ROOT"]
            objects[target + "_BUILD"] = ["isa": "PBXBuildFile", "fileRef": target + "_CATALOG"]
            objects[target + "_RESOURCES"] = ["isa": "PBXResourcesBuildPhase", "files": [target + "_BUILD"]]
        }
        try plist(["rootObject": "ROOT", "objects": objects], at: url.appendingPathComponent("project.pbxproj"))
        return url
    }

    func modify(_ project: URL, _ body: (inout [String: [String: Any]]) -> Void) throws {
        let file = project.appendingPathComponent("project.pbxproj")
        var data = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as! [String: Any]
        var objects = data["objects"] as! [String: [String: Any]]
        body(&objects)
        data["objects"] = objects
        try plist(data, at: file)
    }

    func icon(_ target: String, catalog: String = "Assets", name: String = "AppIcon", color: IconColor) throws {
        try icon(target, catalog: catalog, name: name, images: [IconImage("icon.png", size: 128, color: color)])
    }

    func icon(_ target: String, catalog: String = "Assets", name: String = "AppIcon", images: [IconImage]) throws {
        let directory = root.appendingPathComponent("\(target)/\(catalog).xcassets/\(name).appiconset")
        var entries: [[String: Any]] = []
        for image in images {
            try png(at: directory.appendingPathComponent(image.filename), size: image.size, color: image.color)
            var entry: [String: Any] = ["filename": image.filename, "idiom": image.idiom, "size": "\(image.size)x\(image.size)", "scale": "1x"]
            if let appearance = image.appearance { entry["appearances"] = [["appearance": "luminosity", "value": appearance]] }
            entries.append(entry)
        }
        let data = try JSONSerialization.data(withJSONObject: ["images": entries, "info": ["version": 1, "author": "xcode"]])
        try data.write(to: directory.appendingPathComponent("Contents.json"))
    }

    func scheme(_ name: String, in container: URL, references: [(String, String)], runnable: (String, String)? = nil) throws {
        func reference(_ value: (String, String)) -> String {
            "<BuildableReference BlueprintIdentifier=\"\(value.0)\" ReferencedContainer=\"container:\(value.1)\"/>"
        }
        let entries = references.map { "<BuildActionEntry buildForRunning=\"YES\">\(reference($0))</BuildActionEntry>" }.joined()
        let launch = runnable.map { "<LaunchAction><BuildableProductRunnable>\(reference($0))</BuildableProductRunnable></LaunchAction>" } ?? ""
        try text("<Scheme><BuildAction><BuildActionEntries>\(entries)</BuildActionEntries></BuildAction>\(launch)</Scheme>",
                 at: container.appendingPathComponent("xcshareddata/xcschemes/\(name).xcscheme"))
    }

    func workspace(_ name: String, members: [String]) throws -> URL {
        let url = root.appendingPathComponent(name + ".xcworkspace")
        try text("<Workspace>" + members.map { "<FileRef location=\"group:\($0)\"/>" }.joined() + "</Workspace>",
                 at: url.appendingPathComponent("contents.xcworkspacedata"))
        return url
    }

    func builtApp(for request: ProjectIconRequest, bundleID: String, color: IconColor) throws -> URL {
        let support = try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let derived = support.appendingPathComponent("SwiftDeck/DerivedData/\(request.projectID.uuidString)")
        derivedData = derived
        let app = derived.appendingPathComponent("Build/Products/\(request.configuration)-iphonesimulator/\(request.scheme).app")
        try png(at: app.appendingPathComponent("CompiledIcon@2x.png"), size: 120, color: color)
        try plist(["CFBundleIdentifier": bundleID, "CFBundleExecutable": request.scheme, "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
                   "CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconName": "AppIcon", "CFBundleIconFiles": ["CompiledIcon"]]]],
                  at: app.appendingPathComponent("Info.plist"))
        return app
    }

    func png(at url: URL, size: Int, color: IconColor) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: color == .red ? 1 : 0, green: 0, blue: color == .blue ? 1 : 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    func text(_ string: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(string.utf8).write(to: url)
    }

    func plist(_ dictionary: [String: Any], at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0).write(to: url)
    }
}
