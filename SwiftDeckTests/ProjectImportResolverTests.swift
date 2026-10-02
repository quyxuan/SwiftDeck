import Foundation
import Testing
@testable import SwiftDeck

@Suite("Project import resolution")
@MainActor
struct ProjectImportResolverTests {
    @Test(arguments: ["xcodeproj", "xcworkspace"])
    func acceptsDirectPackageWithoutInspectingItsContents(extension packageExtension: String) async throws {
        let files = try ImportFiles()
        defer { files.remove() }
        let package = try files.directory("Example.\(packageExtension)")
        _ = try files.directory("Example.\(packageExtension)/project.xcworkspace")

        #expect(try await ProjectImportResolver.candidates(at: package) == [package])
    }

    @Test func rejectsEmptyDirectory() async throws {
        let files = try ImportFiles()
        defer { files.remove() }

        await #expect(throws: ToolchainError.self) {
            try await ProjectImportResolver.candidates(at: files.root)
        }
    }

    @Test func returnsAllImmediateChoicesInNaturalNameOrderWithoutPreferringWorkspaces() async throws {
        let files = try ImportFiles()
        defer { files.remove() }
        let workspace = try files.directory("App10.xcworkspace")
        let project = try files.directory("App2.xcodeproj")

        #expect(try await ProjectImportResolver.candidates(at: files.root) == [project, workspace])
    }

    @Test func skipsHiddenChildrenFilesAndNestedProjects() async throws {
        let files = try ImportFiles()
        defer { files.remove() }
        let project = try files.directory("Visible.xcodeproj")
        _ = try files.directory("Visible.xcodeproj/project.xcworkspace")
        _ = try files.directory("Nested/Nested.xcodeproj")
        _ = try files.directory("Pods/Pods.xcodeproj")
        _ = try files.directory(".Hidden.xcworkspace")
        try Data().write(to: files.root.appendingPathComponent("NotAPackage.xcodeproj"))

        #expect(try await ProjectImportResolver.candidates(at: files.root) == [project])
    }

    @Test func rejectsFolderWhoseOnlyProjectsAreNested() async throws {
        let files = try ImportFiles()
        defer { files.remove() }
        _ = try files.directory("Nested/App.xcodeproj")
        _ = try files.directory("Pods/Pods.xcodeproj")

        await #expect(throws: ToolchainError.self) {
            try await ProjectImportResolver.candidates(at: files.root)
        }
    }

    @Test func deduplicatesSymlinkAliasesByCanonicalPath() async throws {
        let files = try ImportFiles()
        defer { files.remove() }
        let project = try files.directory("App.xcodeproj")
        let workspace = try files.directory("App.xcworkspace")
        try files.symlink("Alias.xcodeproj", to: project)
        try files.symlink("AliasWithoutExtension", to: project)
        try files.symlink("WorkspaceAlias.xcworkspace", to: workspace)

        #expect(try await ProjectImportResolver.candidates(at: files.root) == [project, workspace])
    }

    @Test func resolvesDirectPackageAndContainingFolderSymlinks() async throws {
        let files = try ImportFiles()
        defer { files.remove() }
        let container = try files.directory("Projects")
        let project = try files.directory("Projects/App.xcodeproj")
        let packageAlias = try files.symlink("ProjectLink", to: project)
        let folderAlias = try files.symlink("FolderLink", to: container)

        #expect(try await ProjectImportResolver.candidates(at: packageAlias) == [project])
        #expect(try await ProjectImportResolver.candidates(at: folderAlias) == [project])
    }

    @Test func acceptsImmediatePackageSymlinkWithoutScanningOtherLinkedFolders() async throws {
        let files = try ImportFiles()
        defer { files.remove() }
        let selectedFolder = try files.directory("Selected")
        let externalFolder = try files.directory("Elsewhere")
        let project = try files.directory("Elsewhere/App.xcodeproj")
        _ = try files.directory("Elsewhere/Other.xcworkspace")
        try files.symlink("Selected/LinkedProject.xcodeproj", to: project)
        try files.symlink("Selected/LinkedFolder", to: externalFolder)

        #expect(try await ProjectImportResolver.candidates(at: selectedFolder) == [project])
    }

    @Test func rejectsMissingFilesRegularFilesAndRemoteURLs() async throws {
        let files = try ImportFiles()
        defer { files.remove() }
        let regularFile = files.root.appendingPathComponent("File.xcodeproj")
        try Data().write(to: regularFile)
        let missingPackage = files.root.appendingPathComponent("Missing.xcworkspace")
        let brokenAlias = try files.symlink("Broken.xcodeproj", to: missingPackage)
        let remoteURL = try #require(URL(string: "https://example.com/App.xcodeproj"))

        for input in [regularFile, missingPackage, brokenAlias, remoteURL] {
            await #expect(throws: ToolchainError.self) {
                try await ProjectImportResolver.candidates(at: input)
            }
        }
    }
}

private struct ImportFiles {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftDeck-ImportTest-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func symlink(_ path: String, to destination: URL) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
