import Foundation
import Testing
@testable import SwiftDeck

@Suite("App-wide simulator ownership")
@MainActor
struct SimulatorOperationRegistryTests {
    @Test func everyRunMustReleaseBeforeManagementCanStart() throws {
        let registry = SimulatorOperationRegistry()
        let device = UUID()
        let first = try #require(registry.acquire(.run, on: device, label: "Running"))
        let second = try #require(registry.acquire(.run, on: device, label: "Building"))
        #expect(registry.acquire(.management, on: device, label: "Restarting") == nil)
        registry.release(first)
        registry.release(first)
        #expect(!registry.canAcquire(.management, on: device))
        registry.release(second)
        #expect(registry.canAcquire(.management, on: device))
    }

    @Test func managementExcludesSameDeviceButNotOtherDevices() throws {
        let registry = SimulatorOperationRegistry()
        let device = UUID()
        let lease = try #require(registry.acquire(.management, on: device, label: "Booting"))
        #expect(!registry.canAcquire(.run, on: device))
        #expect(!registry.canAcquire(.utility, on: device))
        #expect(!registry.canAcquire(.display, on: device))
        #expect(!registry.canAcquire(.management, on: device))
        #expect(registry.canAcquire(.management, on: UUID()))
        registry.release(lease)
        #expect(registry.canAcquire(.run, on: device))
    }

    @Test func utilitiesCanObserveRunWithoutReleasingItsOwnership() throws {
        let registry = SimulatorOperationRegistry()
        let device = UUID()
        let run = try #require(registry.acquire(.run, on: device, label: "Running"))
        let screenshot = try #require(registry.acquire(.utility, on: device, label: "Saving Screenshot"))
        #expect(!registry.canAcquire(.management, on: device))
        registry.release(screenshot)
        #expect(!registry.canAcquire(.management, on: device))
        #expect(registry.canAcquire(.utility, on: device))
        registry.release(run)
        #expect(registry.canAcquire(.management, on: device))
    }

    @Test func embeddedDisplayIsSharedByRunsButExclusiveAcrossWindows() throws {
        let registry = SimulatorOperationRegistry()
        let device = UUID()
        let display = try #require(registry.acquire(.display, on: device, label: "Embedded"))
        let firstRun = try #require(registry.acquire(.run, on: device, label: "First"))
        let secondRun = try #require(registry.acquire(.run, on: device, label: "Second"))
        let screenshot = try #require(registry.acquire(.utility, on: device, label: "Screenshot"))
        #expect(registry.isEmbedded(device))
        #expect(!registry.canAcquire(.display, on: device))
        #expect(!registry.canAcquire(.management, on: device))
        #expect(registry.canAcquire(.display, on: UUID()))
        registry.release(screenshot)
        registry.release(display)
        #expect(!registry.isEmbedded(device))
        #expect(registry.canAcquire(.display, on: device))
        #expect(!registry.canAcquire(.management, on: device))
        registry.release(firstRun)
        registry.release(secondRun)
        #expect(registry.canAcquire(.management, on: device))
    }

    @Test func embeddedShutdownWaitsForEveryOtherDeviceOperation() throws {
        let registry = SimulatorOperationRegistry()
        let device = UUID()
        #expect(!registry.canManageAfterDetachingDisplay(on: device))
        let display = try #require(registry.acquire(.display, on: device, label: "Embedded"))
        #expect(registry.canManageAfterDetachingDisplay(on: device))
        let run = try #require(registry.acquire(.run, on: device, label: "Building"))
        let utility = try #require(registry.acquire(.utility, on: device, label: "Screenshot"))
        #expect(!registry.canManageAfterDetachingDisplay(on: device))
        registry.release(run)
        #expect(!registry.canManageAfterDetachingDisplay(on: device))
        registry.release(utility)
        #expect(registry.canManageAfterDetachingDisplay(on: device))
        registry.release(display)
        let interveningRun = try #require(registry.acquire(.run, on: device, label: "New Run"))
        #expect(registry.acquire(.management, on: device, label: "Shutdown") == nil)
        registry.release(interveningRun)
        #expect(registry.acquire(.management, on: device, label: "Shutdown") != nil)
    }
}
