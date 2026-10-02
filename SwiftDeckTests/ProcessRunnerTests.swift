import Darwin
import Foundation
import Testing
@testable import SwiftDeck

@Suite("Owned subprocess output and cancellation")
@MainActor
struct ProcessRunnerTests {
    @Test func drainsStdoutAndStderrBeyondPipeCapacity() async throws {
        let script = """
        (i=0; while [ "$i" -lt 2048 ]; do printf 'out:%0128d\\n' "$i"; i=$((i + 1)); done; printf 'stdout-finished\\n') &
        (i=0; while [ "$i" -lt 2048 ]; do printf 'err:%0128d\\n' "$i"; i=$((i + 1)); done; printf 'stderr-finished\\n') >&2 &
        wait
        """
        var streamed: [String] = []
        let result = try await ProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            onOutput: { streamed.append($0) }
        )
        #expect(result.exitCode == 0 && !result.outputTruncated)
        #expect(result.stdout.split(separator: "\n").count == 2049)
        #expect(result.stderr.split(separator: "\n").count == 2049)
        #expect(result.stdout.hasSuffix("stdout-finished\n"))
        #expect(result.stderr.hasSuffix("stderr-finished\n"))
        #expect(streamed.contains("stdout-finished") && streamed.contains("stderr-finished"))
    }

    @Test func preservesSplitUTF8AndUnterminatedFinalLines() async throws {
        // Split both multibyte characters across separate writes/reads.
        let script = #"printf 'caf\303'; /bin/sleep 0.05; printf '\251 \316'; /bin/sleep 0.05; printf '\251\nlast'; printf 'error-tail' >&2"#
        var streamed: [String] = []
        let result = try await ProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            onOutput: { streamed.append($0) }
        )
        #expect(result.stdout == "café Ω\nlast")
        #expect(result.stderr == "error-tail")
        #expect(streamed.filter { $0 == "café Ω" }.count == 1)
        #expect(streamed.contains("last") && streamed.contains("error-tail"))
    }

    @Test func flushesOrderedOutputBeforeFailureIncludingFinalPartialLine() async throws {
        var streamed: [String] = []
        do {
            _ = try await ProcessRunner().run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "i=0; while [ \"$i\" -lt 1025 ]; do printf '%s\\n' \"$i\"; i=$((i + 1)); done; printf 'final partial'; exit 9"],
                onOutput: { streamed.append($0) }
            )
            Issue.record("Nonzero exit incorrectly reported success")
        } catch ToolchainError.commandFailed(_, let exitCode, _) {
            #expect(exitCode == 9)
            #expect(streamed == (0..<1025).map(String.init) + ["final partial"])
        }
    }

    @Test func cancellationDrainsUnterminatedOutputBeforeReturning() async throws {
        var streamed: [String] = []
        let task = Task {
            try await ProcessRunner().run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'ready\\nfinal partial'; exec /bin/sleep 30"],
                onOutput: { streamed.append($0) }
            )
        }
        defer { task.cancel() }
        try await waitUntil { streamed.contains("ready") }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled process incorrectly reported success")
        } catch is CancellationError {
            #expect(streamed == ["ready", "final partial"])
        }
    }

    @Test func nonzeroExitRetainsStatusAndActualErrorOutput() async throws {
        do {
            _ = try await ProcessRunner().run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'actual tool error' >&2; exit 17"]
            )
            Issue.record("Nonzero exit incorrectly reported success")
        } catch ToolchainError.commandFailed(_, let exitCode, let details) {
            #expect(exitCode == 17)
            #expect(details == "actual tool error")
        }
    }

    @Test func cancellationBeforeLaunchHasNoFilesystemEffect() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            try await ProcessRunner().run(
                executable: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path]
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled process incorrectly reported success")
        } catch is CancellationError {}
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func cancellationEscalatesAndWaitsForTermIgnoringProcessGroup() async throws {
        let script = """
        trap '' TERM
        /bin/sh -c 'trap "" TERM; exec /bin/sleep 30' &
        child=$!
        printf '%s:%s\\n' "$$" "$child"
        wait
        """
        var ownedPIDs: [Int32] = []
        let task = Task {
            try await ProcessRunner().run(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                onOutput: { line in ownedPIDs = line.split(separator: ":").compactMap { Int32($0) } }
            )
        }
        defer {
            task.cancel()
            // Failure-only cleanup is restricted to these exact test-owned PIDs.
            for pid in ownedPIDs where kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
        }
        try await waitUntil { ownedPIDs.count == 2 }
        #expect(ownedPIDs.allSatisfy { kill($0, 0) == 0 })
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled process incorrectly reported success")
        } catch is CancellationError {}
        // The direct child is reaped by the runner; launchd reaps the orphaned descendant.
        try await waitUntil { ownedPIDs.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
    }

    @Test func normalExitStillCleansDescendantsThatClosedOutputPipes() async throws {
        let script = """
        /bin/sh -c 'trap "" TERM; exec /bin/sleep 30' >/dev/null 2>&1 &
        printf '%s\\n' "$!"
        exit 0
        """
        var childPID: Int32?
        defer {
            if let childPID, kill(childPID, 0) == 0 { _ = kill(childPID, SIGKILL) }
        }
        _ = try await ProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            onOutput: { childPID = Int32($0) }
        )
        let pid = try #require(childPID)
        try await waitUntil { kill(pid, 0) == -1 && errno == ESRCH }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ProcessTestTimeout() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct ProcessTestTimeout: Error {}
