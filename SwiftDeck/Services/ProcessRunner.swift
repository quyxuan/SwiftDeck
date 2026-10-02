import Foundation
import Darwin

nonisolated struct ProcessResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let outputTruncated: Bool
}

nonisolated enum ToolchainError: LocalizedError {
    case message(String)
    case commandFailed(command: String, exitCode: Int32, details: String)
    case cleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .cleanupFailed(let message): return "App cleanup failed: \(message)"
        case .commandFailed(let command, let exitCode, let details):
            return "\(command) exited with status \(exitCode).\n\(details)"
        }
    }
}

/// Every invocation owns a new process group, including build-script descendants.
@MainActor
struct ProcessRunner {
    func run(
        executable: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval? = nil,
        onOutput: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        guard executable.isFileURL, executable.path.hasPrefix("/"),
              !arguments.contains(where: { $0.contains("\0") }) else {
            throw ToolchainError.message("A local absolute executable and valid arguments are required.")
        }
        let worker = ProcessWorker(
            executable: executable.path, arguments: arguments,
            timeoutSeconds: timeoutSeconds, onOutput: onOutput
        )
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let outcome = Result { try worker.execute() }
                    // All output callbacks are queued before completion on the same queue.
                    DispatchQueue.main.async { continuation.resume(with: outcome) }
                }
            }
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            let details = result.stderr.isEmpty ? result.stdout : result.stderr
            throw ToolchainError.commandFailed(
                command: ([executable.lastPathComponent] + arguments).joined(separator: " "),
                exitCode: result.exitCode,
                details: String(details.suffix(16_384))
            )
        }
        return result
    }
}

/// Blocking POSIX work is confined to one background queue. Only cancellation crosses threads.
nonisolated private final class ProcessWorker: @unchecked Sendable {
    private let executable: String
    private let arguments: [String]
    private let onOutput: @MainActor (String) -> Void
    private let timeoutSeconds: TimeInterval?
    private let lock = NSLock()
    private var cancelled = false
    private let captureLimit = 8 * 1_024 * 1_024
    private var outputBatch: [String] = []
    private var outputBatchBytes = 0

    init(executable: String, arguments: [String], timeoutSeconds: TimeInterval?, onOutput: @escaping @MainActor (String) -> Void) {
        self.executable = executable
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
        self.onOutput = onOutput
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func execute() throws -> ProcessResult {
        defer { flushOutput() }
        if isCancelled { throw CancellationError() }
        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0 else { throw posixError("Creating output pipe") }
        guard pipe(&stderrPipe) == 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1])
            throw posixError("Creating error pipe")
        }
        defer {
            close(stdoutPipe[0]); close(stdoutPipe[1])
            close(stderrPipe[0]); close(stderrPipe[1])
        }
        // CLOEXEC prevents concurrent invocations from inheriting one another's pipes.
        for fd in stdoutPipe + stderrPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try checkSpawnSetup(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checkSpawnSetup(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try checkSpawnSetup(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try checkSpawnSetup(posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO))
        try checkSpawnSetup(posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO))
        for fd in stdoutPipe + stderrPipe {
            try checkSpawnSetup(posix_spawn_file_actions_addclose(&actions, fd))
        }
        try checkSpawnSetup(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try checkSpawnSetup(posix_spawnattr_setpgroup(&attributes, 0))
        let strings = ([executable] + arguments).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        guard strings.allSatisfy({ $0 != nil }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM))
        }
        var argv = strings + [nil]
        let environmentStrings = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        defer { environmentStrings.forEach { free($0) } }
        guard environmentStrings.allSatisfy({ $0 != nil }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM))
        }
        var environment = environmentStrings + [nil]
        var pid: pid_t = 0
        // Cancellation just before spawn is handled immediately after spawn, before returning.
        if isCancelled { throw CancellationError() }
        let spawnError = posix_spawn(&pid, executable, &actions, &attributes, &argv, &environment)
        guard spawnError == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(spawnError), userInfo: [
                NSLocalizedDescriptionKey: "Cannot execute \(executable): \(String(cString: strerror(spawnError))). Select a full Xcode installation with xcode-select or DEVELOPER_DIR."
            ])
        }
        close(stdoutPipe[1]); stdoutPipe[1] = -1
        close(stderrPipe[1]); stderrPipe[1] = -1
        _ = fcntl(stdoutPipe[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(stderrPipe[0], F_SETFL, O_NONBLOCK)
        var captures = [CapturedBytes(limit: captureLimit), CapturedBytes(limit: captureLimit)]
        var pending = [Data(), Data()]
        defer {
            for tail in pending where !tail.isEmpty {
                emit(String(decoding: tail, as: UTF8.self))
            }
        }
        var truncated = false
        var terminationTime: UInt64?
        var rootExited = false
        var sentKill = false
        let descriptors = [stdoutPipe[0], stderrPipe[0]]
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var timedOut = false
        while true {
            for index in descriptors.indices {
                // Bound each turn so continuous output cannot starve cancellation.
                for _ in 0..<16 {
                    let count = Darwin.read(descriptors[index], &buffer, buffer.count)
                    if count <= 0 { break }
                    let chunk = Data(buffer.prefix(count))
                    truncated = captures[index].append(chunk) || truncated
                    pending[index].append(chunk)
                    emitLines(&pending[index])
                }
            }
            flushOutput()
            var info = siginfo_t()
            // Keep the leader unreaped until group cleanup finishes, preventing PID reuse.
            let waitResult = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if waitResult == 0, info.si_pid == pid { rootExited = true }
            if waitResult != 0, errno != EINTR {
                let error = posixError("Waiting for tool")
                kill(-pid, SIGKILL)
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                throw error
            }
            if let timeoutSeconds, !rootExited {
                timedOut = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000 >= timeoutSeconds
            }
            if rootExited, terminationTime == nil, !isCancelled, !timedOut {
                // The unreaped leader reserves its process-group ID. Two slots suffice:
                // only the leader means no descendants can still own output or spawn work.
                var members: (pid_t, pid_t) = (0, 0)
                let bytes = proc_listpids(
                    UInt32(PROC_PGRP_ONLY), UInt32(pid), &members,
                    Int32(MemoryLayout.size(ofValue: members))
                )
                if bytes == MemoryLayout<pid_t>.stride, members.0 == pid { break }
            }
            if (isCancelled || rootExited || timedOut), terminationTime == nil {
                kill(-pid, SIGTERM)
                terminationTime = DispatchTime.now().uptimeNanoseconds
            }
            if let start = terminationTime,
               DispatchTime.now().uptimeNanoseconds - start >= 500_000_000 {
                if !sentKill { kill(-pid, SIGKILL); sentKill = true }
                if rootExited { break }
            }
            usleep(20_000)
        }
        // Drain the final bytes after all owned writers have been stopped.
        for index in descriptors.indices {
            while true {
                let count = Darwin.read(descriptors[index], &buffer, buffer.count)
                if count <= 0 { break }
                let chunk = Data(buffer.prefix(count))
                truncated = captures[index].append(chunk) || truncated
                pending[index].append(chunk)
                emitLines(&pending[index])
            }
            if !pending[index].isEmpty {
                emit(String(decoding: pending[index], as: UTF8.self))
                pending[index].removeAll()
            }
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        if isCancelled { throw CancellationError() }
        if timedOut {
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
                NSLocalizedDescriptionKey: "\(executable) timed out after \(timeoutSeconds ?? 0) seconds; its process group was terminated."
            ])
        }
        let signal = status & 0x7f
        let exitCode = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        return ProcessResult(
            stdout: captures[0].string,
            stderr: captures[1].string,
            exitCode: exitCode, outputTruncated: truncated
        )
    }

    private func emitLines(_ pending: inout Data) {
        var lineStart = pending.startIndex
        for index in pending.indices where pending[index] == 10 {
            var line = pending[lineStart..<index]
            if line.last == 13 { line = line.dropLast() }
            emit(String(decoding: line, as: UTF8.self))
            lineStart = index + 1
        }
        if lineStart != pending.startIndex { pending.removeSubrange(..<lineStart) }
        if pending.count >= 65_536 {
            var boundary = pending.index(pending.startIndex, offsetBy: 65_536)
            // Do not split a UTF-8 scalar when bounding a newline-free stream.
            while boundary < pending.endIndex && boundary > pending.startIndex
                    && pending[boundary] & 0xc0 == 0x80 {
                boundary -= 1
            }
            if boundary == pending.endIndex, let last = pending.last, last >= 0x80 {
                // Retain the final scalar until the next read establishes its full length.
                boundary -= 1
                while boundary > pending.startIndex && pending[boundary] & 0xc0 == 0x80 {
                    boundary -= 1
                }
            }
            emit(String(decoding: pending[..<boundary], as: UTF8.self))
            pending.removeSubrange(..<boundary)
        }
    }

    private func emit(_ line: String) {
        outputBatch.append(line)
        outputBatchBytes += line.utf8.count
        if outputBatch.count >= 256 || outputBatchBytes >= 65_536 { flushOutput() }
    }

    private func flushOutput() {
        guard !outputBatch.isEmpty else { return }
        let batch = outputBatch
        outputBatch = []
        outputBatchBytes = 0
        let callback = onOutput
        // One bounded hop, with backpressure, instead of one synchronous main hop per line.
        // Completion (including cancellation/errors) cannot overtake this final delivery.
        DispatchQueue.main.sync {
            for line in batch { callback(line) }
        }
    }

    private func posixError(_ operation: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"
        ])
    }
}

/// Chunked tail capture avoids shifting/copying an 8 MB buffer on every pipe read.
nonisolated private struct CapturedBytes {
    let limit: Int
    private var chunks: [Data] = []
    private var first = 0
    private var count = 0

    init(limit: Int) { self.limit = limit }

    mutating func append(_ data: Data) -> Bool {
        chunks.append(data)
        count += data.count
        let truncated = count > limit
        while count > limit {
            let excess = count - limit
            if chunks[first].count <= excess {
                count -= chunks[first].count
                chunks[first] = Data()
                first += 1
            } else {
                chunks[first].removeFirst(excess)
                count -= excess
            }
        }
        if first >= 256 {
            chunks.removeFirst(first)
            first = 0
        }
        return truncated
    }

    var string: String {
        var data = Data()
        data.reserveCapacity(count)
        for chunk in chunks[first...] { data.append(chunk) }
        return String(decoding: data, as: UTF8.self)
    }
}

nonisolated private func checkSpawnSetup(_ code: Int32) throws {
    guard code == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "Configuring owned tool process: \(String(cString: strerror(code)))"
        ])
    }
}
