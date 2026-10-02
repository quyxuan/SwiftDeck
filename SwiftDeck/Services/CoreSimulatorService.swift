import Darwin
import Foundation

@MainActor
final class CoreSimulatorService: SimulatorServiceProtocol {
    private let runner = ProcessRunner()
    private let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    // Shared across windows/service instances; a second install must not replace an owned app.
    private static var sessions = Set<String>()
    private var pendingCleanup: [String: PendingCleanup] = [:]
    private var cleanupRetry: Task<Void, Error>?

    private struct PendingCleanup {
        let bundleIdentifier: String
        let deviceID: String
        let launchedPID: Int32?
        let directory: URL
    }

    func loadSimulators() async throws -> [SimulatorModel] {
        let inventory = try await inventory()
        try Task.checkCancellation()
        let runtimes = Dictionary(uniqueKeysWithValues: inventory.runtimes.map { ($0.identifier, $0) })
        return inventory.devices.flatMap { runtimeID, devices -> [SimulatorModel] in
            guard runtimeID.contains(".iOS-") else { return [] }
            let runtime = runtimes[runtimeID]
            return devices.map { device in
                SimulatorModel(
                    id: device.udid, name: device.name,
                    runtime: runtime?.name ?? runtimeID,
                    status: !device.isAvailable || runtime?.isAvailable == false ? .unavailable :
                        Self.status(for: device.state),
                    storageBytes: device.dataPathSize,
                    dataPath: device.dataPath
                )
            }
        }.sorted {
            if $0.runtime != $1.runtime { return $0.runtime.localizedStandardCompare($1.runtime) == .orderedDescending }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func run(
        _ artifact: BuildArtifact,
        on simulatorID: UUID,
        onOutput: @escaping @MainActor (String) -> Void,
        onLaunch: @escaping @MainActor (Int32) -> Void,
        onConflict: @escaping @MainActor (RunningAppConflict) async -> Bool
    ) async throws {
        try Task.checkCancellation()
        let deviceID = simulatorID.uuidString
        let key = "\(deviceID)/\(artifact.bundleIdentifier)"
        guard Self.sessions.insert(key).inserted else {
            throw ToolchainError.message("This app already has an active SwiftDeck session on the selected simulator. Stop that session first.")
        }
        defer {
            if pendingCleanup[key] == nil { Self.sessions.remove(key) }
        }
        let device = try await availableDevice(simulatorID)
        guard device.state == "Shutdown" || device.state == "Booted" || device.state == "Booting" else {
            throw ToolchainError.message("\(device.name) is \(device.state). Wait for the device transition to finish and run again.")
        }
        try Task.checkCancellation()
        if device.state == "Shutdown" {
            onOutput("Booting \(device.name)…")
            _ = try await simctl(["boot", deviceID], onOutput: onOutput)
        }
        try Task.checkCancellation()
        _ = try await simctl(["bootstatus", deviceID, "-b"], timeoutSeconds: 180, onOutput: onOutput)
        try Task.checkCancellation()
        try await resolveExternalAppConflict(
            bundleIdentifier: artifact.bundleIdentifier, simulatorID: simulatorID,
            simulatorName: device.name, onOutput: onOutput, onConflict: onConflict
        )
        try Task.checkCancellation()
        onOutput("Installing \(artifact.appURL.lastPathComponent)…")
        _ = try await simctl(["install", deviceID, artifact.appURL.path], onOutput: onOutput)
        try Task.checkCancellation()
        // Check again after installation, because a user may launch the app independently.
        try await resolveExternalAppConflict(
            bundleIdentifier: artifact.bundleIdentifier, simulatorID: simulatorID,
            simulatorName: device.name, onOutput: onOutput, onConflict: onConflict
        )
        try Task.checkCancellation()
        // simctl output paths are rooted in the device's data directory, not
        // the host filesystem. Keep both views of this owned session path.
        let relativeDirectory = "tmp/SwiftDeck-Session-\(UUID().uuidString)"
        let directory = URL(fileURLWithPath: device.dataPath, isDirectory: true)
            .appendingPathComponent(relativeDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            if pendingCleanup[key] == nil { try? FileManager.default.removeItem(at: directory) }
        }
        let stdout = directory.appendingPathComponent("stdout.log")
        let stderr = directory.appendingPathComponent("stderr.log")
        guard FileManager.default.createFile(atPath: stdout.path, contents: nil),
              FileManager.default.createFile(atPath: stderr.path, contents: nil) else {
            throw ToolchainError.message("Unable to create simulator output files.")
        }
        let output = try SessionOutput(urls: [stdout, stderr])
        defer { Task { await output.close() } }
        var launchedPID: Int32?
        var launchAttempted = false
        let cancellation = LaunchCancellation()
        // simctl --console buffers its PID when stdout is a pipe. A finite launch
        // gives a reliable PID; separate files preserve the app's actual output.
        let launch = Task { @MainActor [self] in
            if cancellation.isCancelled { throw CancellationError() }
            launchAttempted = true
            return try await simctl([
                "launch", "--stdout=/\(relativeDirectory)/stdout.log", "--stderr=/\(relativeDirectory)/stderr.log",
                deviceID, artifact.bundleIdentifier
            ], timeoutSeconds: 30, onOutput: onOutput)
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await launch.value
            } onCancel: {
                // Only the finite PID handshake is shielded. Cleanup follows it.
                cancellation.cancel()
            }
            launchedPID = result.stdout.split(separator: "\n").compactMap {
                launchPID(String($0), bundleIdentifier: artifact.bundleIdentifier)
            }.first
            guard let pid = launchedPID else {
                throw ToolchainError.message("simctl did not report an application PID; launch could not be confirmed.")
            }
            try Task.checkCancellation()
            onLaunch(pid)
            while true {
                try Task.checkCancellation()
                try await output.drain(onOutput)
                guard try await runningPID(bundleIdentifier: artifact.bundleIdentifier, deviceID: deviceID) == pid else {
                    try await output.drain(onOutput, flush: true)
                    break
                }
                try await Task.sleep(for: .milliseconds(500))
            }
        } catch {
            // A cancelled handshake that never started has no app to clean up.
            if launchAttempted {
                let session = PendingCleanup(
                    bundleIdentifier: artifact.bundleIdentifier,
                    deviceID: deviceID,
                    launchedPID: launchedPID,
                    directory: directory
                )
                do {
                    // Cleanup must run even when the parent task has been cancelled.
                    try await Task { @MainActor [self] in
                        try await cleanup(session)
                    }.value
                } catch {
                    pendingCleanup[key] = session
                    throw error
                }
            }
            throw error
        }
    }

    func openSimulator(on simulatorID: UUID?) async throws {
        if let simulatorID { try await requireBooted(simulatorID) }
        let location = try await runner.run(executable: xcrun, arguments: ["--find", "simctl"])
        try Task.checkCancellation()
        let toolURL = URL(fileURLWithPath: location.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        let developer = toolURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let simulator = developer.appendingPathComponent("Applications/Simulator.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: simulator.path) else {
            throw ToolchainError.message("Simulator.app is missing from the selected Xcode installation: \(simulator.path). Select a full Xcode installation.")
        }
        var arguments = ["-a", simulator.path]
        if let simulatorID {
            arguments += ["--args", "-CurrentDeviceUDID", simulatorID.uuidString]
        }
        _ = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/open"), arguments: arguments)
    }

    func bootAndOpen(_ simulatorID: UUID) async throws {
        try await boot(simulatorID)
        try await openSimulator(on: simulatorID)
    }

    private func boot(_ simulatorID: UUID) async throws {
        let device = try await availableDevice(simulatorID)
        switch device.state {
        case "Shutdown":
            _ = try await simctl(["boot", simulatorID.uuidString])
        case "Booted", "Booting":
            break
        default:
            throw ToolchainError.message("\(device.name) is \(device.state). Wait for the device transition to finish and refresh.")
        }
        _ = try await simctl(["bootstatus", simulatorID.uuidString, "-b"], timeoutSeconds: 180)
        try Task.checkCancellation()
    }

    func shutdown(_ simulatorID: UUID) async throws {
        let device = try await availableDevice(simulatorID)
        if device.state == "Shutdown" { return }
        if device.state != "Shutting Down" {
            _ = try await simctl(["shutdown", simulatorID.uuidString], timeoutSeconds: 60)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while try await availableDevice(simulatorID).state != "Shutdown" {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw ToolchainError.message("Timed out waiting for \(device.name) to shut down. Refresh to see its current state.")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    func restart(_ simulatorID: UUID) async throws {
        try await shutdown(simulatorID)
        try Task.checkCancellation()
        try await boot(simulatorID)
    }

    func screenshot(_ simulatorID: UUID, to url: URL) async throws {
        try await requireBooted(simulatorID)
        _ = try await simctl(["io", simulatorID.uuidString, "screenshot", "--type=png", url.path], timeoutSeconds: 30)
    }

    func openURL(_ url: URL, on simulatorID: UUID) async throws {
        try await requireBooted(simulatorID)
        _ = try await simctl(["openurl", simulatorID.uuidString, url.absoluteString], timeoutSeconds: 30)
    }

    private func availableDevice(_ simulatorID: UUID) async throws -> Device {
        let snapshot = try await inventory()
        try Task.checkCancellation()
        let runtimes = Dictionary(uniqueKeysWithValues: snapshot.runtimes.map { ($0.identifier, $0) })
        guard let pair = snapshot.devices.first(where: { runtimeID, devices in
            runtimeID.contains(".iOS-") && runtimes[runtimeID]?.isAvailable != false
                && devices.contains(where: { $0.udid == simulatorID })
        }), let device = pair.value.first(where: { $0.udid == simulatorID }), device.isAvailable else {
            throw ToolchainError.message("The selected iOS Simulator is no longer available. Refresh the simulator list.")
        }
        return device
    }

    private func requireBooted(_ simulatorID: UUID) async throws {
        guard try await availableDevice(simulatorID).state == "Booted" else {
            throw ToolchainError.message("This action requires a booted simulator. Boot it and try again.")
        }
    }

    private static func status(for state: String) -> SimulatorStatus {
        switch state {
        case "Booted": .booted
        case "Booting": .booting
        case "Shutting Down": .shuttingDown
        case "Shutdown": .available
        default: .unavailable
        }
    }

    func retryPendingCleanup() async throws {
        if let cleanupRetry {
            try await cleanupRetry.value
            return
        }
        let retry = Task { @MainActor [self] in
            var firstFailure: Error?
            for (key, session) in pendingCleanup {
                do {
                    try await cleanup(session)
                    try? FileManager.default.removeItem(at: session.directory)
                    pendingCleanup.removeValue(forKey: key)
                    Self.sessions.remove(key)
                } catch {
                    if firstFailure == nil { firstFailure = error }
                }
            }
            if let firstFailure { throw firstFailure }
        }
        cleanupRetry = retry
        defer { cleanupRetry = nil }
        try await retry.value
    }

    private func resolveExternalAppConflict(
        bundleIdentifier: String,
        simulatorID: UUID,
        simulatorName: String,
        onOutput: @escaping @MainActor (String) -> Void,
        onConflict: @escaping @MainActor (RunningAppConflict) async -> Bool
    ) async throws {
        let deviceID = simulatorID.uuidString
        let inspectedPID = try await runningPID(bundleIdentifier: bundleIdentifier, deviceID: deviceID)
        try Task.checkCancellation()
        guard let pid = inspectedPID else { return }
        let conflict = RunningAppConflict(
            bundleIdentifier: bundleIdentifier, simulatorID: simulatorID,
            simulatorName: simulatorName, pid: pid
        )
        guard await onConflict(conflict) else { throw CancellationError() }
        try Task.checkCancellation()
        onOutput("Stopping external \(bundleIdentifier) (PID \(pid)) on \(simulatorName)…")
        let confirmedPID = try await runningPID(bundleIdentifier: bundleIdentifier, deviceID: deviceID)
        try Task.checkCancellation()
        guard let confirmedPID else { return }
        guard confirmedPID == pid else {
            throw ToolchainError.message("\(bundleIdentifier) relaunched as PID \(confirmedPID) on \(simulatorName) while awaiting confirmation. The replacement was not stopped. Run again to confirm stopping the current app.")
        }
        // Consent applies only to this PID. Never use bundle-targeted termination,
        // or owned-session cleanup that could retry after the request is cancelled.
        do {
            try signal(pid, SIGTERM)
        } catch {
            throw ToolchainError.message("Could not stop \(bundleIdentifier) (PID \(pid)) on \(simulatorName): \(error.localizedDescription). Quit the app in Simulator and run again.")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            try Task.checkCancellation()
            let currentPID = try await runningPID(bundleIdentifier: bundleIdentifier, deviceID: deviceID)
            try Task.checkCancellation()
            guard let currentPID else { return }
            guard currentPID == pid else {
                throw ToolchainError.message("\(bundleIdentifier) relaunched as PID \(currentPID) on \(simulatorName) while stopping the confirmed app. The replacement was not stopped. Run again to confirm stopping the current app.")
            }
            guard ContinuousClock.now < deadline else {
                throw ToolchainError.message("\(bundleIdentifier) (PID \(pid)) is still running on \(simulatorName). Quit the app in Simulator and run again.")
            }
            try await Task.sleep(for: .milliseconds(100))
        } while true
    }

    private func cleanup(_ session: PendingCleanup) async throws {
        do {
            guard let currentPID = try await runningPID(
                bundleIdentifier: session.bundleIdentifier, deviceID: session.deviceID
            ) else { return }
            guard let launchedPID = session.launchedPID else {
                // Never guess ownership when the finite launch did not return its PID.
                throw ToolchainError.cleanupFailed("An app is running but simctl did not report its PID. It was not terminated because ownership cannot be established; quit it in Simulator.")
            }
            guard currentPID == launchedPID else { return }
            // Simulator app PIDs are host PIDs. Do not await a bundle-targeted
            // simctl terminate: the bundle may have relaunched by the time it runs.
            try signal(launchedPID, SIGTERM)
            if try await waitForExit(session, pid: launchedPID) { return }
            // Revalidate immediately before escalation, without another suspension.
            guard try await runningPID(
                bundleIdentifier: session.bundleIdentifier, deviceID: session.deviceID
            ) == launchedPID else { return }
            try signal(launchedPID, SIGKILL)
            guard try await waitForExit(session, pid: launchedPID) else {
                throw ToolchainError.cleanupFailed("The launched app (PID \(launchedPID)) is still running on simulator \(session.deviceID).")
            }
        } catch let error as ToolchainError {
            if case .cleanupFailed = error { throw error }
            throw ToolchainError.cleanupFailed(error.localizedDescription)
        } catch {
            throw ToolchainError.cleanupFailed(error.localizedDescription)
        }
    }

    private func signal(_ pid: Int32, _ signal: Int32) throws {
        guard Darwin.kill(pid, signal) == -1 else { return }
        let code = errno
        guard code != ESRCH else { return }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private func waitForExit(_ session: PendingCleanup, pid: Int32) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            if try await runningPID(
                bundleIdentifier: session.bundleIdentifier, deviceID: session.deviceID
            ) != pid { return true }
            if ContinuousClock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(100))
        } while true
    }

    private func runningPID(bundleIdentifier: String, deviceID: String) async throws -> Int32? {
        let result: ProcessResult
        do {
            result = try await simctl(["spawn", deviceID, "launchctl", "list"], timeoutSeconds: 15)
        } catch {
            try Task.checkCancellation()
            // A completed device shutdown ends every app session. launchctl cannot
            // run there; confirm current device state instead of retaining a false
            // cleanup failure. Also covers shutdown during monitoring/escalation.
            let snapshot = try await inventory()
            guard snapshot.devices.values.joined().contains(where: {
                $0.udid.uuidString.caseInsensitiveCompare(deviceID) == .orderedSame && $0.state == "Shutdown"
            }) else { throw error }
            return nil
        }
        guard !result.outputTruncated else {
            throw ToolchainError.message("Simulator process inventory exceeded the capture limit; app ownership cannot be checked.")
        }
        for line in result.stdout.split(separator: "\n") {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 3,
                  columns[2].hasPrefix("UIKitApplication:\(bundleIdentifier)["),
                  let pid = Int32(columns[0]), pid > 0 else { continue }
            return pid
        }
        return nil
    }

    private func launchPID(_ line: String, bundleIdentifier: String) -> Int32? {
        let prefix = bundleIdentifier + ": "
        guard line.hasPrefix(prefix), let pid = Int32(line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)), pid > 0 else { return nil }
        return pid
    }

    private func inventory() async throws -> Inventory {
        let result = try await simctl(["list", "--json"])
        guard !result.outputTruncated else {
            throw ToolchainError.message("CoreSimulator inventory exceeded the 8 MiB capture limit.")
        }
        do {
            return try await Self.decodeInventory(result.stdout)
        } catch {
            throw ToolchainError.message("Could not read CoreSimulator inventory: \(error.localizedDescription)\n\(result.stderr.suffix(4_096))")
        }
    }

    @concurrent
    private static func decodeInventory(_ json: String) async throws -> Inventory {
        try Task.checkCancellation()
        return try JSONDecoder().decode(Inventory.self, from: Data(json.utf8))
    }

    private func simctl(
        _ arguments: [String],
        timeoutSeconds: TimeInterval? = nil,
        onOutput: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        return try await runner.run(
            executable: xcrun, arguments: ["simctl"] + arguments,
            timeoutSeconds: timeoutSeconds, onOutput: onOutput
        )
    }

    nonisolated private struct Inventory: Decodable, Sendable {
        let devices: [String: [Device]]
        let runtimes: [Runtime]
    }

    nonisolated private struct Device: Decodable, Sendable {
        let udid: UUID
        let name: String
        let state: String
        let isAvailable: Bool
        let dataPath: String
        let dataPathSize: Int64?
    }

    nonisolated private struct Runtime: Decodable, Sendable {
        let identifier: String
        let name: String
        let isAvailable: Bool
    }

    actor SessionOutput {
        private var handles: [FileHandle] = []
        private let urls: [URL]
        private var pending = [Data(), Data()]

        init(urls: [URL]) throws {
            self.urls = urls
            do {
                for url in urls { handles.append(try FileHandle(forReadingFrom: url)) }
            } catch {
                for handle in handles { try? handle.close() }
                throw error
            }
        }

        func close() {
            for handle in handles { try? handle.close() }
            handles.removeAll()
        }

        func drain(_ output: @escaping @MainActor @Sendable (String) -> Void, flush: Bool = false) async throws {
            let totalSize = try urls.reduce(UInt64(0)) { total, url in
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                return total + ((attributes[.size] as? NSNumber)?.uint64Value ?? 0)
            }
            guard totalSize <= 64 * 1_024 * 1_024 else {
                throw ToolchainError.message("App console output exceeded 64 MiB. The session was stopped to protect disk space; reduce app logging before running again.")
            }
            for index in handles.indices {
                var reads = 0
                while flush || reads < 16 {
                    guard let data = try handles[index].read(upToCount: 16_384), !data.isEmpty else { break }
                    reads += 1
                    pending[index].append(data)
                    var lines: [String] = []
                    while let newline = pending[index].firstIndex(of: 10) {
                        lines.append(String(decoding: pending[index][..<newline], as: UTF8.self))
                        pending[index].removeSubrange(...newline)
                    }
                    if pending[index].count > 65_536 {
                        let end = completeUTF8PrefixEnd(pending[index])
                        lines.append(String(decoding: pending[index][..<end], as: UTF8.self))
                        pending[index].removeSubrange(..<end)
                    }
                    let batch = lines
                    if !batch.isEmpty {
                        await MainActor.run { for line in batch { output(line) } }
                    }
                }
                if flush, !pending[index].isEmpty {
                    let line = String(decoding: pending[index], as: UTF8.self)
                    await output(line)
                    pending[index].removeAll()
                }
            }
        }

        private func completeUTF8PrefixEnd(_ data: Data) -> Data.Index {
            var start = data.index(before: data.endIndex)
            while start > data.startIndex, data[start] & 0xC0 == 0x80 {
                start = data.index(before: start)
            }
            let lead = data[start]
            let width: Int
            switch lead {
            case 0xC2...0xDF: width = 2
            case 0xE0...0xEF: width = 3
            case 0xF0...0xF4: width = 4
            default: return data.endIndex
            }
            return data.distance(from: start, to: data.endIndex) < width ? start : data.endIndex
        }
    }
}

nonisolated private final class LaunchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
