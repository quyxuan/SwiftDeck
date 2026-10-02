import AppKit
import Combine
import Foundation

@MainActor
final class ProjectIconStore {
    static let shared = ProjectIconStore()

    let invalidations = PassthroughSubject<ProjectIconRequest, Never>()

    private struct Entry {
        let image: NSImage?
        let loadedAt: Date
        var lastAccess: UInt64
    }

    private struct Flight {
        let id: UUID
        let task: Task<NSImage?, Never>
        var waiters: Set<UUID>
    }

    private let capacity: Int
    private let resolve: @Sendable (ProjectIconRequest) async -> Data?
    private let now: () -> Date
    private var entries: [ProjectIconRequest: Entry] = [:]
    private var inFlight: [ProjectIconRequest: Flight] = [:]
    private var access: UInt64 = 0

    init(
        capacity: Int = 128,
        now: @escaping () -> Date = Date.init,
        resolve: @escaping @Sendable (ProjectIconRequest) async -> Data? = {
            await ProjectIconResolver.resolve($0)
        }
    ) {
        self.capacity = max(1, capacity)
        self.now = now
        self.resolve = resolve
    }

    func image(for request: ProjectIconRequest) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        if var entry = entries[request] {
            access &+= 1
            entry.lastAccess = access
            entries[request] = entry
            return entry.image
        }

        let waiter = UUID()
        let flight: Flight
        if var existing = inFlight[request] {
            existing.waiters.insert(waiter)
            inFlight[request] = existing
            flight = existing
        } else {
            let id = UUID()
            let task = Task { [weak self, resolve] in
                let data = await resolve(request)
                guard !Task.isCancelled, let self, self.inFlight[request]?.id == id else {
                    return nil as NSImage?
                }
                // The resolver already downsamples to a tiny PNG off the main actor.
                let image = data.flatMap { NSImage(data: $0) }
                self.inFlight.removeValue(forKey: request)
                self.access &+= 1
                self.entries[request] = Entry(image: image, loadedAt: self.now(), lastAccess: self.access)
                if self.entries.count > self.capacity,
                   let oldest = self.entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
                    self.entries.removeValue(forKey: oldest)
                }
                return image
            }
            flight = Flight(id: id, task: task, waiters: [waiter])
            inFlight[request] = flight
        }

        let flightID = flight.id
        return await withTaskCancellationHandler {
            let image = await flight.task.value
            return Task.isCancelled || flight.task.isCancelled ? nil : image
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiter, for: request, flightID: flightID)
            }
        }
    }

    func invalidate(_ request: ProjectIconRequest) {
        entries.removeValue(forKey: request)
        inFlight.removeValue(forKey: request)?.task.cancel()
        invalidations.send(request)
    }

    func refreshIfStale(_ request: ProjectIconRequest) {
        // Foreground changes are cheap unless this visible request is at least a minute old.
        // Missing icons use the same cache and retry policy as successful resolutions.
        guard let entry = entries[request], now().timeIntervalSince(entry.loadedAt) >= 60 else { return }
        invalidate(request)
    }

    private func cancelWaiter(_ waiter: UUID, for request: ProjectIconRequest, flightID: UUID) {
        guard var flight = inFlight[request], flight.id == flightID else { return }
        flight.waiters.remove(waiter)
        if flight.waiters.isEmpty {
            inFlight.removeValue(forKey: request)
            flight.task.cancel()
        } else {
            inFlight[request] = flight
        }
    }
}
