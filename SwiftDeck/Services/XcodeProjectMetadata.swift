import Foundation

/// Only valid containers with Xcode-generated schemes use the authoritative toolchain path.
nonisolated enum XcodeGeneratedMetadataRequired: Error, Equatable, Sendable {
    case standalonePackage
    case legacyWatchTarget
}

/// Import reads declarations, not the build graph: xcodebuild -list also resolves/downloads packages.
nonisolated struct XcodeProjectMetadata: Sendable {
    let name: String
    let schemes: [String]
    let configurations: [String]

    @concurrent
    static func read(at url: URL) async throws -> Self {
        var reader = Reader()
        let workspace = url.pathExtension == "xcodeproj" ? url.appendingPathComponent("project.xcworkspace") : url
        let autocreate = try reader.autocreatesSchemes(in: workspace)
        try reader.readContainer(url, autocreate: autocreate)
        return try reader.metadata(named: url.deletingPathExtension().lastPathComponent)
    }
}

nonisolated private struct Reader {
    private struct Target {
        let id: String
        let name: String
        let project: URL
        let productType: String
        let autocreate: Bool
    }

    private var visited = Set<URL>()
    private var schemes = Set<String>()
    private var configurations = Set<String>()
    private var targets: [Target] = []
    private var suppressedTargets = Set<String>()
    private var referencedTestTargets = Set<String>()
    private var generatedMetadataRequirement: XcodeGeneratedMetadataRequired?

    mutating func readContainer(_ location: URL, autocreate: Bool = true) throws {
        try Task.checkCancellation()
        let url = location.standardizedFileURL.resolvingSymlinksInPath()
        guard visited.insert(url).inserted else { return }
        switch url.pathExtension {
        case "xcodeproj":
            try readProject(url, autocreate: autocreate)
            try readSchemes(in: url, autocreate: autocreate)
            let workspace = url.appendingPathComponent("project.xcworkspace")
            if FileManager.default.fileExists(atPath: workspace.path) {
                try readSchemes(in: workspace, autocreate: autocreate)
            }
        case "xcworkspace":
            let documentURL = url.appendingPathComponent("contents.xcworkspacedata")
            let root = try xmlRoot(at: documentURL, named: "Workspace")
            try readWorkspaceElements(root, group: url.deletingLastPathComponent(), workspace: url, autocreate: autocreate)
            try readSchemes(in: url, autocreate: autocreate)
        default:
            throw invalid(url, "Expected an Xcode project or workspace.")
        }
    }

    func metadata(named name: String) throws -> XcodeProjectMetadata {
        var names = schemes
        var requirement = generatedMetadataRequirement
        for target in targets where target.autocreate {
            try Task.checkCancellation()
            let key = targetKey(target.id, project: target.project)
            guard !suppressedTargets.contains(key) else { continue }
            if target.productType == "com.apple.product-type.bundle.unit-test"
                || target.productType == "com.apple.product-type.bundle.ui-testing" {
                guard !referencedTestTargets.contains(key) else { continue }
            }
            // Legacy watch targets can generate contextual schemes absent from their declarations.
            if target.productType == "com.apple.product-type.application.watchapp"
                || target.productType == "com.apple.product-type.watchkit-extension" {
                requirement = .legacyWatchTarget
            }
            names.insert(target.name)
        }
        // Finish validating every member before delegating: corruption must not trigger a fallback.
        if let requirement { throw requirement }
        return XcodeProjectMetadata(name: name, schemes: names.sorted(), configurations: configurations.sorted())
    }

    private mutating func readProject(_ url: URL, autocreate: Bool) throws {
        let file = url.appendingPathComponent("project.pbxproj")
        let plist = try dictionary(at: file)
        guard let objects = plist["objects"] as? [String: [String: Any]],
              let rootID = plist["rootObject"] as? String,
              let project = objects[rootID], project["isa"] as? String == "PBXProject",
              let targetIDs = project["targets"] as? [String] else {
            throw invalid(file, "The project object or target list is missing.")
        }
        try readConfigurations(project, objects: objects, file: file)
        for id in targetIDs {
            guard let target = objects[id], let name = target["name"] as? String,
                  let kind = target["isa"] as? String,
                  ["PBXNativeTarget", "PBXAggregateTarget", "PBXLegacyTarget"].contains(kind) else {
                throw invalid(file, "Unsupported or missing target \(id). Share its scheme in Xcode and check the project format.")
            }
            if kind == "PBXNativeTarget", target["productType"] as? String == nil {
                throw invalid(file, "Native target \(name) has no product type.")
            }
            try readConfigurations(target, objects: objects, file: file)
            targets.append(Target(id: id, name: name, project: url,
                                  productType: target["productType"] as? String ?? "", autocreate: autocreate))
        }
        let references = project["projectReferences"] as? [[String: Any]] ?? []
        if !references.isEmpty {
            guard let group = project["mainGroup"] as? String else {
                throw invalid(file, "The project reference group is missing.")
            }
            var paths: [String: URL] = [:]
            var groups = Set<String>()
            let root = url.deletingLastPathComponent().appendingPathComponent(project["projectDirPath"] as? String ?? "")
            try projectPaths(group, parent: root, root: root, objects: objects, paths: &paths, visited: &groups)
            for reference in references {
                guard let id = reference["ProjectRef"] as? String, let member = paths[id] else {
                    throw invalid(file, "A referenced project has no resolvable path.")
                }
                try readContainer(member, autocreate: autocreate)
            }
        }
    }

    private mutating func readConfigurations(_ owner: [String: Any], objects: [String: [String: Any]], file: URL) throws {
        guard let id = owner["buildConfigurationList"] as? String,
              let list = objects[id], let ids = list["buildConfigurations"] as? [String] else {
            throw invalid(file, "A build configuration list is missing.")
        }
        for id in ids {
            guard let configuration = objects[id], configuration["isa"] as? String == "XCBuildConfiguration",
                  let name = configuration["name"] as? String, !name.isEmpty else {
                throw invalid(file, "Build configuration \(id) is missing or invalid.")
            }
            configurations.insert(name)
        }
    }

    private mutating func readWorkspaceElements(_ element: XMLElement, group: URL, workspace: URL, autocreate: Bool) throws {
        for child in element.children ?? [] {
            try Task.checkCancellation()
            guard let child = child as? XMLElement else { continue }
            switch child.name {
            case "Group":
                let path = try child.attribute(forName: "location").map {
                    try workspaceLocation($0.stringValue ?? "", group: group, workspace: workspace)
                } ?? group
                try readWorkspaceElements(child, group: path, workspace: workspace, autocreate: autocreate)
            case "FileRef":
                guard let location = child.attribute(forName: "location")?.stringValue else {
                    throw invalid(workspace, "A workspace member has no location.")
                }
                let member = try workspaceLocation(location, group: group, workspace: workspace)
                if ["xcodeproj", "xcworkspace"].contains(member.pathExtension) {
                    try readContainer(member, autocreate: autocreate)
                } else if member.lastPathComponent == "Package.swift"
                    || FileManager.default.fileExists(atPath: member.appendingPathComponent("Package.swift").path) {
                    let manifest = member.lastPathComponent == "Package.swift" ? member : member.appendingPathComponent("Package.swift")
                    do {
                        _ = try Data(contentsOf: manifest)
                    } catch {
                        throw invalid(manifest, error.localizedDescription)
                    }
                    generatedMetadataRequirement = .standalonePackage
                }
            default: break
            }
        }
    }

    private mutating func readSchemes(in container: URL, autocreate: Bool) throws {
        let shared = container.appendingPathComponent("xcshareddata/xcschemes")
        let user = container.appendingPathComponent("xcuserdata/\(NSUserName()).xcuserdatad/xcschemes")
        var base = container.deletingLastPathComponent()
        if base.pathExtension == "xcodeproj" { base.deleteLastPathComponent() }
        for directory in [shared, user] {
            let management = directory.appendingPathComponent("xcschememanagement.plist")
            if FileManager.default.fileExists(atPath: management.path) {
                let data = try dictionary(at: management)
                if let entries = data["SuppressBuildableAutocreation"] as? [String: [String: Any]] {
                    for (id, entry) in entries where (entry["primary"] as? NSNumber)?.boolValue == true {
                        if container.pathExtension == "xcodeproj" {
                            suppressedTargets.insert(targetKey(id, project: container))
                        } else {
                            // Workspace management stores target IDs across its member projects.
                            for target in targets where target.id == id {
                                suppressedTargets.insert(targetKey(id, project: target.project))
                            }
                        }
                    }
                }
            }
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "xcscheme" {
                try Task.checkCancellation()
                let scheme = try xmlRoot(at: file, named: "Scheme")
                schemes.insert(file.deletingPathExtension().lastPathComponent)
                for node in try scheme.nodes(forXPath: ".//*[@buildConfiguration]") {
                    if let name = (node as? XMLElement)?.attribute(forName: "buildConfiguration")?.stringValue {
                        configurations.insert(name)
                    }
                }
                for node in try scheme.nodes(forXPath: ".//BuildableReference") {
                    guard let reference = node as? XMLElement,
                          let id = reference.attribute(forName: "BlueprintIdentifier")?.stringValue,
                          let location = reference.attribute(forName: "ReferencedContainer")?.stringValue else {
                        throw invalid(file, "A scheme buildable reference is incomplete.")
                    }
                    let project = try workspaceLocation(location, group: base, workspace: container, containerRoot: base)
                        .standardizedFileURL.resolvingSymlinksInPath()
                    if project.pathExtension == "xcodeproj" {
                        referencedTestTargets.insert(targetKey(id, project: project))
                        try readContainer(project, autocreate: autocreate)
                    }
                }
            }
        }
    }

    func autocreatesSchemes(in workspace: URL) throws -> Bool {
        for location in ["xcuserdata/\(NSUserName()).xcuserdatad/WorkspaceSettings.xcsettings", "xcshareddata/WorkspaceSettings.xcsettings"] {
            let file = workspace.appendingPathComponent(location)
            if FileManager.default.fileExists(atPath: file.path),
               let enabled = try dictionary(at: file)["IDEWorkspaceSharedSettings_AutocreateContextsIfNeeded"] as? NSNumber {
                return enabled.boolValue
            }
        }
        return true
    }

    private func projectPaths(_ id: String, parent: URL, root: URL, objects: [String: [String: Any]],
                              paths: inout [String: URL], visited: inout Set<String>) throws {
        try Task.checkCancellation()
        guard visited.insert(id).inserted, let object = objects[id] else { return }
        let path = object["path"] as? String ?? ""
        let location: URL
        switch object["sourceTree"] as? String ?? "<group>" {
        case "<group>": location = parent.appendingPathComponent(path)
        case "SOURCE_ROOT": location = root.appendingPathComponent(path)
        case "<absolute>": location = URL(fileURLWithPath: path)
        default: return // Built products are not project references.
        }
        paths[id] = location
        for child in object["children"] as? [String] ?? [] {
            try projectPaths(child, parent: location, root: root, objects: objects, paths: &paths, visited: &visited)
        }
    }

    private func workspaceLocation(_ location: String, group: URL, workspace: URL, containerRoot: URL? = nil) throws -> URL {
        guard let separator = location.firstIndex(of: ":") else {
            throw invalid(workspace, "Unsupported workspace location: \(location).")
        }
        let path = String(location[location.index(after: separator)...])
        switch location[..<separator] {
        case "group": return group.appendingPathComponent(path)
        case "container", "self": return (containerRoot ?? workspace.deletingLastPathComponent()).appendingPathComponent(path)
        case "absolute": return URL(fileURLWithPath: path)
        default: throw invalid(workspace, "Unsupported workspace location: \(location).")
        }
    }

    private func dictionary(at file: URL) throws -> [String: Any] {
        do {
            guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any] else {
                throw invalid(file, "Expected a property-list dictionary.")
            }
            return value
        } catch {
            throw invalid(file, error.localizedDescription)
        }
    }

    private func xmlRoot(at file: URL, named name: String) throws -> XMLElement {
        do {
            let document = try XMLDocument(contentsOf: file, options: [.nodeLoadExternalEntitiesNever])
            guard let root = document.rootElement(), root.name == name else {
                throw invalid(file, "Expected a \(name) XML document.")
            }
            return root
        } catch {
            throw invalid(file, error.localizedDescription)
        }
    }

    private func targetKey(_ id: String, project: URL) -> String { project.path + ":" + id }

    private func invalid(_ url: URL, _ reason: String) -> ToolchainError {
        .message("Could not read Xcode metadata at \(url.path): \(reason)")
    }
}
