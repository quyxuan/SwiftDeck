import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin
import CryptoKit

nonisolated struct ProjectIconRequest: Hashable, Sendable {
    let projectID: UUID
    let projectPath: String
    let scheme: String
    let configuration: String
}

/// Reads only the selected target's declarations and resources; never asks Xcode to resolve a build graph.
nonisolated enum ProjectIconResolver {
    @concurrent
    static func resolve(_ request: ProjectIconRequest) async -> Data? {
        do {
            try Task.checkCancellation()
            var reader = IconProjectReader(request: request)
            guard let selection = try reader.selection() else { return nil }
            if let built = try? builtIcon(selection, request: request) { return built }
            guard let source = try reader.sourceIcon(selection) else { return nil }
            let result: Data?
            if source.pathExtension == "icon" {
                result = try await renderIconPackage(source)
            } else {
                result = try thumbnail(source)
            }
            try Task.checkCancellation()
            return result
        } catch {
            // Missing, ambiguous, unsupported and cancelled requests all retain the sidebar's default icon.
            return nil
        }
    }

    private static func builtIcon(_ selection: IconSelection, request: ProjectIconRequest) throws -> Data? {
        guard let bundleID = selection.bundleID, let product = selection.product,
              !product.contains("/"), !request.configuration.contains("/"),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let app = support.appendingPathComponent("SwiftDeck/DerivedData/\(request.projectID.uuidString)/Build/Products")
            .appendingPathComponent("\(request.configuration)-iphonesimulator")
            .appendingPathComponent("\(product).app")
        guard let info = try? iconDictionary(app.appendingPathComponent("Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundleExecutable"] as? String == selection.executable,
              (info["CFBundleSupportedPlatforms"] as? [String])?.contains("iPhoneSimulator") == true else { return nil }
        let icons = info["CFBundleIcons"] as? [String: Any]
        guard let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any],
              primary["CFBundleIconName"] as? String == selection.iconName,
              let names = primary["CFBundleIconFiles"] as? [String] else { return nil }
        return try thumbnailFromBundle(app, names: names)
    }

    private static func thumbnailFromBundle(_ directory: URL, names: [String]) throws -> Data? {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard files.count <= 2_048 else { throw IconReadError.unsupported }
        let candidates = files.filter { file in
            guard file.pathExtension.lowercased() == "png" else { return false }
            let stem = file.deletingPathExtension().lastPathComponent
            return names.contains { name in
                let base = (name as NSString).deletingPathExtension
                return stem == base || stem.hasPrefix(base + "@") || stem.hasPrefix(base + "~")
            }
        }
        return try bestThumbnail(candidates)
    }

    /// Icon Composer layers are not standalone artwork. Apple's asset compiler renders the complete package,
    /// including fill, placement and materials, into a private temporary directory without building the project.
    private static func renderIconPackage(_ source: URL) async throws -> Data? {
        let developer: String
        if let override = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !override.isEmpty {
            developer = override.hasSuffix(".app") ? override + "/Contents/Developer" : override
        } else {
            let result = try await ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/xcode-select"), arguments: ["-p"], timeoutSeconds: 5)
            developer = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let tool = URL(fileURLWithPath: developer).appendingPathComponent("usr/bin/actool")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { return nil }
        let key = try packageCacheKey(source, tool: tool)
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SwiftDeck/ProjectIcons", isDirectory: true)
        let cached = cache?.appendingPathComponent(key + ".png")
        if let cached, let data = try? thumbnail(cached) { return data }
        let ticket = UUID()
        return try await withTaskCancellationHandler {
            try await IconRenderGate.shared.acquire(ticket)
            do {
                try Task.checkCancellation()
                // Another request can have rendered the same package while this one waited.
                if let cached, let data = try? thumbnail(cached) {
                    await IconRenderGate.shared.release()
                    return data
                }
                let data = try await compileIconPackage(source, tool: tool)
                if let data, let cached, let cache {
                    try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                    try? data.write(to: cached, options: .atomic)
                    pruneCache(cache)
                }
                await IconRenderGate.shared.release()
                return data
            } catch {
                await IconRenderGate.shared.release()
                throw error
            }
        } onCancel: {
            Task { await IconRenderGate.shared.cancel(ticket) }
        }
    }

    private static func compileIconPackage(_ source: URL, tool: URL) async throws -> Data? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftDeck-Icon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: output) }
        let info = output.appendingPathComponent("Info.plist")
        _ = try await ProcessRunner().run(executable: tool, arguments: [
            "--compile", output.path, "--platform", "iphonesimulator", "--minimum-deployment-target", "26.0",
            "--app-icon", source.deletingPathExtension().lastPathComponent,
            "--output-partial-info-plist", info.path, source.path
        ], timeoutSeconds: 45)
        try Task.checkCancellation()
        let metadata = try iconDictionary(info)
        let icons = metadata["CFBundleIcons"] as? [String: Any]
        guard let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any],
              let names = primary["CFBundleIconFiles"] as? [String] else { return nil }
        return try thumbnailFromBundle(output, names: names)
    }

    private static func packageCacheKey(_ source: URL, tool: URL) throws -> String {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
            throw IconReadError.unsupported
        }
        var files = [tool.resolvingSymlinksInPath()]
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            guard files.count < 512, file.pathComponents.count - source.pathComponents.count < 10 else { throw IconReadError.unsupported }
            files.append(file)
        }
        var hash = SHA256()
        hash.update(data: Data("icon-v1|iphonesimulator|26.0|96|\(source.resolvingSymlinksInPath().path)".utf8))
        for file in files.sorted(by: { $0.path < $1.path }) {
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw IconReadError.unsupported }
            hash.update(data: Data("\n\(file.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)".utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func pruneCache(_ directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let thumbnails = files.filter { $0.pathExtension == "png" }.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        for old in thumbnails.dropFirst(64) { try? FileManager.default.removeItem(at: old) }
    }

    private static func bestThumbnail(_ files: [URL]) throws -> Data? {
        for file in try rankedIconSources(files) {
            if let data = try thumbnail(file) { return data }
        }
        return nil
    }

    private static func thumbnail(_ file: URL) throws -> Data? {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 96,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        try Task.checkCancellation()
        return data as Data
    }
}

/// Serializes only expensive Apple compiler invocations, with cancellable queued requests.
private actor IconRenderGate {
    static let shared = IconRenderGate()
    private var occupied = false
    private var waiters: [(UUID, CheckedContinuation<Void, any Error>)] = []

    func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            if occupied { waiters.append((id, continuation)) }
            else { occupied = true; continuation.resume() }
        }
    }

    func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }

    func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().1.resume() }
    }
}

nonisolated private enum IconReadError: Error { case unsupported }

nonisolated private struct IconSelection {
    let project: URL
    let targetID: String
    let iconName: String
    let bundleID: String?
    let product: String?
    let executable: String?
    let settings: [String: String]
}

nonisolated private struct IconProject {
    let root: URL
    let objects: [String: [String: Any]]
    let project: [String: Any]
    let paths: [String: URL]
}

nonisolated private struct IconProjectReader {
    let request: ProjectIconRequest
    private var projects: [URL: IconProject] = [:]
    private var containers: [URL] = []
    private var visited = Set<URL>()
    private var remainingFiles = 8_000

    init(request: ProjectIconRequest) { self.request = request }

    mutating func selection() throws -> IconSelection? {
        guard !request.scheme.isEmpty, !request.configuration.isEmpty,
              !request.scheme.contains("/"), !request.configuration.contains("/") else { return nil }
        try readContainer(URL(fileURLWithPath: request.projectPath))
        var selected = Set<String>()
        var references: [String: (URL, String)] = [:]
        var explicit = false
        // A scheme may live in the workspace, a member project, or the project's internal workspace.
        // Conflicting definitions are deliberately ambiguous rather than dependent on filesystem ordering.
        for container in containers {
            let base = container.deletingLastPathComponent().pathExtension == "xcodeproj"
                ? container.deletingLastPathComponent().deletingLastPathComponent() : container.deletingLastPathComponent()
            for folder in ["xcshareddata/xcschemes", "xcuserdata/\(NSUserName()).xcuserdatad/xcschemes"] {
                let file = container.appendingPathComponent(folder).appendingPathComponent(request.scheme + ".xcscheme")
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                explicit = true
                let root = try iconXML(file)
                let runnable = try root.nodes(forXPath: "./LaunchAction/BuildableProductRunnable/BuildableReference")
                let nodes = runnable.isEmpty
                    ? try root.nodes(forXPath: "./BuildAction/BuildActionEntries/BuildActionEntry[not(@buildForRunning='NO')]/BuildableReference")
                    : runnable
                var matches = Set<String>()
                for node in nodes {
                    guard let element = node as? XMLElement,
                          let id = element.attribute(forName: "BlueprintIdentifier")?.stringValue,
                          let location = element.attribute(forName: "ReferencedContainer")?.stringValue else { throw IconReadError.unsupported }
                    let projectURL = try locationURL(location, group: base, base: base)
                    try readContainer(projectURL)
                    guard let target = projects[projectURL]?.objects[id] else { throw IconReadError.unsupported }
                    if target["productType"] as? String == "com.apple.product-type.application" {
                        let key = projectURL.path + ":" + id
                        matches.insert(key)
                        references[key] = (projectURL, id)
                    }
                }
                guard matches.count == 1 else { return nil }
                selected.formUnion(matches)
            }
        }
        if !explicit {
            for (url, project) in projects {
                for id in project.project["targets"] as? [String] ?? [] {
                    guard let target = project.objects[id], target["name"] as? String == request.scheme,
                          target["productType"] as? String == "com.apple.product-type.application" else { continue }
                    let key = url.path + ":" + id
                    selected.insert(key)
                    references[key] = (url, id)
                }
            }
        }
        guard selected.count == 1, let key = selected.first, let (url, id) = references[key],
              let project = projects[url], let target = project.objects[id], let targetName = target["name"] as? String else { return nil }
        var settings = ["SRCROOT": project.root.path, "SOURCE_ROOT": project.root.path, "PROJECT_DIR": project.root.path,
                        "TARGET_NAME": targetName, "CONFIGURATION": request.configuration, "PLATFORM_NAME": "iphonesimulator",
                        "PRODUCT_NAME": targetName, "EXECUTABLE_NAME": "$(PRODUCT_NAME)"]
        try applyConfiguration(project.project, project: project, settings: &settings)
        try applyConfiguration(target, project: project, settings: &settings)
        guard let name = expand(settings["ASSETCATALOG_COMPILER_APPICON_NAME"], settings: settings),
              !name.isEmpty, !name.contains("/") else { return nil }
        return IconSelection(project: url, targetID: id, iconName: name,
                             bundleID: expand(settings["PRODUCT_BUNDLE_IDENTIFIER"], settings: settings),
                             product: expand(settings["PRODUCT_NAME"], settings: settings),
                             executable: expand(settings["EXECUTABLE_NAME"], settings: settings), settings: settings)
    }

    mutating func sourceIcon(_ selection: IconSelection) throws -> URL? {
        guard let project = projects[selection.project], let target = project.objects[selection.targetID] else { return nil }
        var resources = Set<URL>()
        for phaseID in target["buildPhases"] as? [String] ?? [] {
            guard project.objects[phaseID]?["isa"] as? String == "PBXResourcesBuildPhase" else { continue }
            for buildID in project.objects[phaseID]?["files"] as? [String] ?? [] {
                guard let build = project.objects[buildID], let id = build["fileRef"] as? String,
                      let path = project.paths[id] else { continue }
                if let filters = build["platformFilters"] as? [String], !filters.isEmpty,
                   !filters.contains("ios") { continue }
                if let filter = build["platformFilter"] as? String, !filter.isEmpty, filter != "ios" { continue }
                if ["icon", "xcassets"].contains(path.pathExtension) { resources.insert(path) }
            }
        }
        for groupID in target["fileSystemSynchronizedGroups"] as? [String] ?? [] {
            guard let group = project.objects[groupID], let root = project.paths[groupID] else { throw IconReadError.unsupported }
            var excluded = Set<String>()
            for id in group["exceptions"] as? [String] ?? [] {
                guard let exception = project.objects[id], exception["target"] as? String == selection.targetID else { continue }
                excluded.formUnion(exception["membershipExceptions"] as? [String] ?? [])
            }
            try discover(root, relative: "", excluded: excluded, depth: 0, results: &resources)
        }
        if let raw = selection.settings["EXCLUDED_SOURCE_FILE_NAMES"] {
            guard let exclusions = expand(raw, settings: selection.settings),
                  !exclusions.contains("\""), !exclusions.contains("'") else { throw IconReadError.unsupported }
            let patterns = exclusions.split(whereSeparator: \.isWhitespace).map(String.init)
            resources = Set(resources.filter { file in
                let rootPrefix = project.root.path + "/"
                let relative = file.path.hasPrefix(rootPrefix) ? String(file.path.dropFirst(rootPrefix.count)) : file.path
                return !patterns.contains {
                    fnmatch($0, file.lastPathComponent, 0) == 0 || fnmatch($0, relative, 0) == 0 || fnmatch($0, file.path, 0) == 0
                }
            })
        }
        let modern = resources.filter { $0.pathExtension == "icon" && $0.deletingPathExtension().lastPathComponent == selection.iconName }
        if !modern.isEmpty { return modern.count == 1 ? modern.first : nil }
        var sets = Set<URL>()
        for catalog in resources where catalog.pathExtension == "xcassets" {
            try findIconSets(catalog, name: selection.iconName, depth: 0, results: &sets)
        }
        guard sets.count == 1, let set = sets.first else { return nil }
        let data = try iconData(set.appendingPathComponent("Contents.json"))
        guard let contents = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = contents["images"] as? [[String: Any]] else { return nil }
        // Light/default artwork only, and never borrow a watch/Mac alternate from the same set.
        let candidates = images.filter {
            guard ($0["appearances"] as? [Any] ?? []).isEmpty else { return false }
            let idiom = $0["idiom"] as? String ?? "universal"
            let platform = $0["platform"] as? String
            return ["universal", "iphone", "ipad", "ios-marketing"].contains(idiom) && (platform == nil || platform == "ios")
        }.compactMap { image -> URL? in
            guard let name = image["filename"] as? String, !name.contains("/"), name != ".." else { return nil }
            return set.appendingPathComponent(name)
        }
        // Keep the same ranking for source images and built images, returning the selected source for downsampling.
        return try rankedIconSources(candidates).first
    }

    private mutating func discover(_ directory: URL, relative: String, excluded: Set<String>, depth: Int, results: inout Set<URL>) throws {
        guard depth < 16 else { throw IconReadError.unsupported }
        for file in try children(directory) {
            let name = relative.isEmpty ? file.lastPathComponent : relative + "/" + file.lastPathComponent
            guard !excluded.contains(where: { name == $0 || name.hasPrefix($0 + "/") }) else { continue }
            if ["icon", "xcassets"].contains(file.pathExtension) { results.insert(file); continue }
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true, values.isSymbolicLink != true,
               !["build", "DerivedData", "Pods", "Carthage", "node_modules"].contains(file.lastPathComponent), file.pathExtension.isEmpty {
                try discover(file, relative: name, excluded: excluded, depth: depth + 1, results: &results)
            }
        }
    }

    private mutating func findIconSets(_ directory: URL, name: String, depth: Int, results: inout Set<URL>) throws {
        guard depth < 16 else { throw IconReadError.unsupported }
        for file in try children(directory) {
            if file.lastPathComponent == name + ".appiconset" { results.insert(file); continue }
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if file.pathExtension.isEmpty, values.isDirectory == true, values.isSymbolicLink != true {
                try findIconSets(file, name: name, depth: depth + 1, results: &results)
            }
        }
    }

    private mutating func children(_ directory: URL) throws -> [URL] {
        try Task.checkCancellation()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        remainingFiles -= files.count
        guard remainingFiles >= 0 else { throw IconReadError.unsupported }
        return files
    }

    private mutating func readContainer(_ input: URL) throws {
        try Task.checkCancellation()
        let url = input.standardizedFileURL.resolvingSymlinksInPath()
        guard visited.insert(url).inserted else { return }
        guard visited.count <= 64 else { throw IconReadError.unsupported }
        containers.append(url)
        if url.pathExtension == "xcworkspace" {
            let root = try iconXML(url.appendingPathComponent("contents.xcworkspacedata"))
            try readWorkspace(root, group: url.deletingLastPathComponent(), base: url.deletingLastPathComponent())
        } else if url.pathExtension == "xcodeproj" {
            let plist = try iconDictionary(url.appendingPathComponent("project.pbxproj"))
            guard let objects = plist["objects"] as? [String: [String: Any]], let rootID = plist["rootObject"] as? String,
                  let project = objects[rootID], let group = project["mainGroup"] as? String else { throw IconReadError.unsupported }
            let root = url.deletingLastPathComponent().appendingPathComponent(project["projectDirPath"] as? String ?? "").standardizedFileURL
            var paths: [String: URL] = [:]
            var seen = Set<String>()
            try groupPaths(group, parent: root, root: root, objects: objects, paths: &paths, seen: &seen)
            projects[url] = IconProject(root: root, objects: objects, project: project, paths: paths)
            let workspace = url.appendingPathComponent("project.xcworkspace")
            if FileManager.default.fileExists(atPath: workspace.path) { containers.append(workspace) }
            for reference in project["projectReferences"] as? [[String: Any]] ?? [] {
                guard let id = reference["ProjectRef"] as? String, let member = paths[id] else { throw IconReadError.unsupported }
                try readContainer(member)
            }
        } else { throw IconReadError.unsupported }
    }

    private mutating func readWorkspace(_ element: XMLElement, group: URL, base: URL) throws {
        for case let child as XMLElement in element.children ?? [] {
            try Task.checkCancellation()
            switch child.name {
            case "Group":
                let next = try child.attribute(forName: "location").map { try locationURL($0.stringValue ?? "", group: group, base: base) } ?? group
                try readWorkspace(child, group: next, base: base)
            case "FileRef":
                guard let location = child.attribute(forName: "location")?.stringValue else { throw IconReadError.unsupported }
                let member = try locationURL(location, group: group, base: base)
                if ["xcodeproj", "xcworkspace"].contains(member.pathExtension) { try readContainer(member) }
            default: break
            }
        }
    }

    private func groupPaths(_ id: String, parent: URL, root: URL, objects: [String: [String: Any]], paths: inout [String: URL], seen: inout Set<String>) throws {
        try Task.checkCancellation()
        guard seen.insert(id).inserted, let object = objects[id] else { return }
        guard seen.count < 50_000 else { throw IconReadError.unsupported }
        let path = object["path"] as? String ?? ""
        guard !path.contains("$("), !path.contains("${") else { return }
        let location: URL
        switch object["sourceTree"] as? String ?? "<group>" {
        case "<group>": location = parent.appendingPathComponent(path)
        case "SOURCE_ROOT": location = root.appendingPathComponent(path)
        case "<absolute>": location = URL(fileURLWithPath: path)
        default: return
        }
        paths[id] = location.standardizedFileURL.resolvingSymlinksInPath()
        for child in object["children"] as? [String] ?? [] {
            try groupPaths(child, parent: location, root: root, objects: objects, paths: &paths, seen: &seen)
        }
    }

    private func applyConfiguration(_ owner: [String: Any], project: IconProject, settings: inout [String: String]) throws {
        guard let listID = owner["buildConfigurationList"] as? String,
              let ids = project.objects[listID]?["buildConfigurations"] as? [String] else { throw IconReadError.unsupported }
        let matches = ids.compactMap { project.objects[$0] }.filter { $0["name"] as? String == request.configuration }
        guard matches.count == 1, let config = matches.first else { throw IconReadError.unsupported }
        if let base = config["baseConfigurationReference"] as? String {
            guard let file = project.paths[base] else { throw IconReadError.unsupported }
            var visited = Set<URL>()
            try readXCConfig(file, settings: &settings, visited: &visited)
        }
        let raw = config["buildSettings"] as? [String: Any] ?? [:]
        // Unconditional assignments precede more-specific overrides. Conflicting equally specific
        // declarations cannot be resolved safely without evaluating Xcode's full setting environment.
        var assignments: [(String, String, Int)] = []
        var variants: [String: String] = [:]
        for rawKey in raw.keys.sorted() {
            guard let key = try matchingKey(rawKey) else { continue }
            let value: String
            if let string = raw[rawKey] as? String { value = string }
            else if let array = raw[rawKey] as? [String] { value = array.joined(separator: " ") }
            else { continue }
            let specificity = rawKey.filter { $0 == "[" }.count
            let variant = "\(key)|\(specificity)"
            if let previous = variants[variant], previous != value { throw IconReadError.unsupported }
            variants[variant] = value
            assignments.append((rawKey, value, specificity))
        }
        for (rawKey, value, _) in assignments.sorted(by: { $0.2 < $1.2 }) {
            try assign(rawKey, value: value, settings: &settings)
        }
    }

    private func readXCConfig(_ input: URL, settings: inout [String: String], visited: inout Set<URL>) throws {
        try Task.checkCancellation()
        let file = input.standardizedFileURL.resolvingSymlinksInPath()
        guard visited.count < 32, visited.insert(file).inserted else { throw IconReadError.unsupported }
        defer { visited.remove(file) }
        guard let text = String(data: try iconData(file), encoding: .utf8) else { throw IconReadError.unsupported }
        var inComment = false
        let joined = text.replacingOccurrences(of: "\\\r\n", with: "").replacingOccurrences(of: "\\\n", with: "")
        for rawLine in joined.components(separatedBy: .newlines) {
            var line = rawLine
            while true {
                if inComment {
                    guard let end = line.range(of: "*/") else { line = ""; break }
                    line = String(line[end.upperBound...]); inComment = false
                }
                guard let start = line.range(of: "/*") else { break }
                if let end = line.range(of: "*/", range: start.upperBound..<line.endIndex) { line.removeSubrange(start.lowerBound..<end.upperBound) }
                else { line = String(line[..<start.lowerBound]); inComment = true; break }
            }
            if let comment = line.range(of: "//") { line = String(line[..<comment.lowerBound]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#include") {
                guard let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\""), first != last,
                      let path = expand(String(line[line.index(after: first)..<last]), settings: settings) else { throw IconReadError.unsupported }
                let included = path.hasPrefix("/") ? URL(fileURLWithPath: path) : file.deletingLastPathComponent().appendingPathComponent(path)
                if line.hasPrefix("#include?"), !FileManager.default.fileExists(atPath: included.path) { continue }
                try readXCConfig(included, settings: &settings, visited: &visited)
                continue
            }
            if line.hasPrefix("#") { throw IconReadError.unsupported }
            var bracket = 0
            guard let equals = line.indices.first(where: { index in
                if line[index] == "[" { bracket += 1 }; if line[index] == "]" { bracket -= 1 }
                return line[index] == "=" && bracket == 0
            }) else { throw IconReadError.unsupported }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            try assign(key, value: value, settings: &settings)
        }
    }

    private func assign(_ rawKey: String, value: String, settings: inout [String: String]) throws {
        guard let key = try matchingKey(rawKey) else { return }
        let inherited = settings[key] ?? ""
        settings[key] = value.replacingOccurrences(of: "$(inherited)", with: inherited).replacingOccurrences(of: "${inherited}", with: inherited)
    }

    private func matchingKey(_ rawKey: String) throws -> String? {
        let parts = rawKey.split(separator: "[", omittingEmptySubsequences: false)
        guard let first = parts.first else { return nil }
        let key = String(first).trimmingCharacters(in: .whitespaces)
        for part in parts.dropFirst() {
            guard part.hasSuffix("]") else { throw IconReadError.unsupported }
            let condition = part.dropLast().split(separator: "=", maxSplits: 1)
            guard condition.count == 2 else { throw IconReadError.unsupported }
            let actual: String
            switch condition[0] {
            case "sdk": actual = "iphonesimulator"
            case "config": actual = request.configuration
            case "arch": actual = "arm64"
            default: throw IconReadError.unsupported
            }
            if fnmatch(String(condition[1]), actual, 0) != 0 { return nil }
        }
        return key
    }
}

nonisolated private func expand(_ value: String?, settings: [String: String], depth: Int = 0) -> String? {
    guard var result = value, depth < 20 else { return nil }
    for opener in ["$(", "${"] {
        let closer: Character = opener == "$(" ? ")" : "}"
        while let start = result.range(of: opener) {
            guard let end = result[start.upperBound...].firstIndex(of: closer) else { return nil }
            let name = String(result[start.upperBound..<end])
            guard let expanded = expand(settings[name], settings: settings, depth: depth + 1) else { return nil }
            result.replaceSubrange(start.lowerBound...end, with: expanded)
        }
    }
    if result.count >= 2, result.hasPrefix("\""), result.hasSuffix("\"") { result = String(result.dropFirst().dropLast()) }
    return result
}

nonisolated private func iconData(_ url: URL) throws -> Data {
    try Task.checkCancellation()
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 8 * 1_024 * 1_024 else { throw IconReadError.unsupported }
    return try Data(contentsOf: url)
}

nonisolated private func iconDictionary(_ url: URL) throws -> [String: Any] {
    guard let value = try PropertyListSerialization.propertyList(from: iconData(url), format: nil) as? [String: Any] else { throw IconReadError.unsupported }
    return value
}

nonisolated private func iconXML(_ url: URL) throws -> XMLElement {
    let document = try XMLDocument(data: iconData(url), options: [.nodeLoadExternalEntitiesNever])
    guard let root = document.rootElement() else { throw IconReadError.unsupported }
    return root
}

nonisolated private func locationURL(_ location: String, group: URL, base: URL) throws -> URL {
    guard let colon = location.firstIndex(of: ":") else { throw IconReadError.unsupported }
    let path = String(location[location.index(after: colon)...])
    let url: URL
    switch location[..<colon] {
    case "group": url = group.appendingPathComponent(path)
    case "container": url = base.appendingPathComponent(path)
    case "absolute": url = URL(fileURLWithPath: path)
    case "self": url = base.appendingPathComponent(path)
    default: throw IconReadError.unsupported
    }
    return url.standardizedFileURL.resolvingSymlinksInPath()
}

nonisolated private func rankedIconSources(_ files: [URL]) throws -> [URL] {
    // Prefer enough pixels for a crisp 2x sidebar, then the smallest sufficient square image.
    try files.compactMap { file -> (URL, Int)? in
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width == height, width > 0 else { return nil }
        return (file, width >= 96 ? width - 96 : 100_000 - width)
    }.sorted {
        $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 < $1.1
    }.map(\.0)
}
