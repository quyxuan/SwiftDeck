import Foundation

struct ProjectImportSelection: Identifiable {
    let id = UUID()
    let candidates: [URL]
}

nonisolated enum ProjectImportResolver {
    @concurrent
    static func candidates(at url: URL) async throws -> [URL] {
        try Task.checkCancellation()
        let guidance = "Choose an existing .xcodeproj or .xcworkspace package, or a folder containing one directly."
        guard url.isFileURL else {
            throw ToolchainError.message(guidance)
        }

        let directory = url.standardizedFileURL.resolvingSymlinksInPath()
        guard isDirectory(directory) else {
            throw ToolchainError.message("The selected location is missing or is not a folder. \(guidance)")
        }
        if isProjectPackage(directory) {
            return [directory]
        }

        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
        } catch {
            throw ToolchainError.message("Could not read \(directory.path): \(error.localizedDescription) \(guidance)")
        }

        var paths = Set<String>()
        var candidates: [URL] = []
        for child in children {
            try Task.checkCancellation()
            let candidate = child.standardizedFileURL.resolvingSymlinksInPath()
            guard isProjectPackage(candidate), isDirectory(candidate),
                  paths.insert(candidate.path).inserted else { continue }
            candidates.append(candidate)
        }
        guard !candidates.isEmpty else {
            throw ToolchainError.message("No Xcode project or workspace was found directly in \(directory.path). \(guidance)")
        }
        return candidates.sorted {
            let order = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.path < $1.path
        }
    }

    private static func isProjectPackage(_ url: URL) -> Bool {
        url.pathExtension == "xcodeproj" || url.pathExtension == "xcworkspace"
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
