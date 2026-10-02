import AppKit
import Foundation
import Testing
@testable import SwiftDeck

@Suite("Sidebar project icon cache")
@MainActor
struct ProjectIconStoreTests {
    @Test func missingIconsAreCachedUntilForegroundRefreshIsDue() async {
        var instant = Date(timeIntervalSince1970: 1_000)
        let resolver = ImmediateIconResolver()
        let store = ProjectIconStore(now: { instant }) { await resolver.resolve($0) }
        let request = request()

        #expect(await store.image(for: request) == nil)
        #expect(await store.image(for: request) == nil)
        #expect(resolver.requests.count == 1)

        instant.addTimeInterval(59)
        store.refreshIfStale(request)
        #expect(await store.image(for: request) == nil)
        #expect(resolver.requests.count == 1)

        instant.addTimeInterval(1)
        store.refreshIfStale(request)
        #expect(await store.image(for: request) == nil)
        #expect(resolver.requests.count == 2)
    }

    @Test func cacheEvictsLeastRecentlyUsedMissingResultAndSeparatesConfigurations() async {
        let resolver = ImmediateIconResolver()
        let store = ProjectIconStore(capacity: 2, resolve: { await resolver.resolve($0) })
        let debug = request()
        let release = ProjectIconRequest(
            projectID: debug.projectID, projectPath: debug.projectPath,
            scheme: debug.scheme, configuration: "Release"
        )
        let another = request()
        _ = await store.image(for: debug)
        _ = await store.image(for: release)
        _ = await store.image(for: debug)
        _ = await store.image(for: another)
        _ = await store.image(for: debug)
        _ = await store.image(for: release)

        #expect(resolver.requests == [debug, release, another, release])
    }

    @Test func cancellingOneRowDoesNotCancelAnotherRowsSharedResolution() async throws {
        let resolver = IconResolutionGate()
        let store = ProjectIconStore(resolve: { await resolver.resolve($0) })
        let request = request()
        let first = await startLoading(store, request: request)
        await resolver.waitForCall(0)
        let second = await startLoading(store, request: request)
        first.cancel()
        resolver.complete(0, with: try thumbnail())

        #expect(await first.value == nil)
        let image = try #require(await second.value)
        #expect(await store.image(for: request) === image)
        #expect(resolver.requests == [request])
    }

    @Test func invalidatedSlowResolutionCannotOverwriteFreshIcon() async throws {
        let resolver = IconResolutionGate()
        let store = ProjectIconStore(resolve: { await resolver.resolve($0) })
        let request = request()
        let old = await startLoading(store, request: request)
        await resolver.waitForCall(0)
        store.invalidate(request)
        let replacement = await startLoading(store, request: request)
        await resolver.waitForCall(1)
        resolver.complete(1, with: try thumbnail())
        let fresh = try #require(await replacement.value)

        // This resolver deliberately finishes even after cancellation.
        resolver.complete(0, with: nil)
        #expect(await old.value == nil)
        #expect(await store.image(for: request) === fresh)
        #expect(resolver.requests.count == 2)
    }

    private func request() -> ProjectIconRequest {
        ProjectIconRequest(
            projectID: UUID(), projectPath: "/Example/Example.xcodeproj",
            scheme: "Example", configuration: "Debug"
        )
    }

    private func startLoading(
        _ store: ProjectIconStore, request: ProjectIconRequest
    ) async -> Task<NSImage?, Never> {
        var task: Task<NSImage?, Never>!
        await withCheckedContinuation { started in
            task = Task {
                started.resume()
                return await store.image(for: request)
            }
        }
        return task
    }

    private func thumbnail() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.setColor(.systemBlue, atX: 0, y: 0)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}

@MainActor
private final class ImmediateIconResolver {
    private(set) var requests: [ProjectIconRequest] = []

    func resolve(_ request: ProjectIconRequest) -> Data? {
        requests.append(request)
        return nil
    }
}

@MainActor
private final class IconResolutionGate {
    private(set) var requests: [ProjectIconRequest] = []
    private var completions: [Int: CheckedContinuation<Data?, Never>] = [:]
    private var callWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func resolve(_ request: ProjectIconRequest) async -> Data? {
        let index = requests.count
        requests.append(request)
        return await withCheckedContinuation { continuation in
            completions[index] = continuation
            callWaiters.removeValue(forKey: index)?.resume()
        }
    }

    func waitForCall(_ index: Int) async {
        guard requests.count <= index else { return }
        await withCheckedContinuation { callWaiters[index] = $0 }
    }

    func complete(_ index: Int, with data: Data?) {
        completions.removeValue(forKey: index)?.resume(returning: data)
    }
}
