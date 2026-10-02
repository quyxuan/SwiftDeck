import Foundation
import Testing
@testable import SwiftDeck

@Suite("Simulator file-backed console output")
@MainActor
struct SessionOutputTests {
    @Test func finalFlushDrainsBothFilesBeyondPollingLimit() async throws {
        let files = try OutputFiles()
        defer { files.remove() }
        let rows = (0..<5_000).map { index in
            let prefix = "row-\(index):"
            return prefix + String(repeating: "x", count: 127 - prefix.utf8.count)
        }
        try Data((rows.joined(separator: "\n") + "\nstdout-tail").utf8).write(to: files.stdout)
        try Data((rows.joined(separator: "\n") + "\nstderr-tail").utf8).write(to: files.stderr)
        let output = try CoreSimulatorService.SessionOutput(urls: files.urls)
        defer { Task { await output.close() } }
        var lines: [String] = []

        try await output.drain { lines.append($0) }
        #expect(lines == Array(rows.prefix(2_048)) + Array(rows.prefix(2_048)))
        lines.removeAll()
        try await output.drain({ lines.append($0) }, flush: true)
        #expect(lines == Array(rows.dropFirst(2_048)) + ["stdout-tail"]
            + Array(rows.dropFirst(2_048)) + ["stderr-tail"])
        lines.removeAll()
        try await output.drain({ lines.append($0) }, flush: true)
        #expect(lines.isEmpty)
    }

    @Test func preservesUTF8AcrossLongPartialLineAndPollingBoundary() async throws {
        let files = try OutputFiles()
        defer { files.remove() }
        let writer = try FileHandle(forWritingTo: files.stdout)
        defer { try? writer.close() }
        let prefix = String(repeating: "a", count: 81_919)
        let character = Array("🙂".utf8)
        try writer.write(contentsOf: Data(prefix.utf8) + Data(character.prefix(1)))
        let output = try CoreSimulatorService.SessionOutput(urls: files.urls)
        defer { Task { await output.close() } }
        var chunks: [String] = []

        try await output.drain { chunks.append($0) }
        #expect(chunks == [prefix])
        try writer.write(contentsOf: Data(character.dropFirst()) + Data("終\nunterminated Ω".utf8))
        try await output.drain({ chunks.append($0) }, flush: true)
        #expect(chunks == [prefix, "🙂終", "unterminated Ω"])
    }

    @Test(arguments: [false, true])
    func rejectsCombinedOutputBeyondDiskLimitBeforeReading(flush: Bool) async throws {
        let files = try OutputFiles()
        defer { files.remove() }
        let stdout = try FileHandle(forWritingTo: files.stdout)
        let stderr = try FileHandle(forWritingTo: files.stderr)
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        // Sparse files exercise the aggregate disk guard without allocating 64 MiB.
        try stdout.truncate(atOffset: 32 * 1_024 * 1_024)
        try stderr.truncate(atOffset: 32 * 1_024 * 1_024 + 1)
        let output = try CoreSimulatorService.SessionOutput(urls: files.urls)
        defer { Task { await output.close() } }
        var lines: [String] = []
        do {
            try await output.drain({ lines.append($0) }, flush: flush)
            Issue.record("Console output beyond the disk limit was accepted")
        } catch ToolchainError.message {}
        #expect(lines.isEmpty)

        try stdout.truncate(atOffset: 0)
        try stderr.truncate(atOffset: 0)
        try stdout.seek(toOffset: 0)
        try stderr.seek(toOffset: 0)
        try stdout.write(contentsOf: Data("stdout after rejection\n".utf8))
        try stderr.write(contentsOf: Data("stderr after rejection".utf8))
        try await output.drain({ lines.append($0) }, flush: true)
        #expect(lines == ["stdout after rejection", "stderr after rejection"])
    }
}

private struct OutputFiles {
    let directory: URL
    let stdout: URL
    let stderr: URL
    var urls: [URL] { [stdout, stderr] }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftDeck-OutputTest-\(UUID().uuidString)", isDirectory: true)
        stdout = directory.appendingPathComponent("stdout.log")
        stderr = directory.appendingPathComponent("stderr.log")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try Data().write(to: stdout)
            try Data().write(to: stderr)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
