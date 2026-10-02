import Combine
import Foundation

/// Device ownership spans windows and begins before a Run's build, not only launch.
@MainActor
final class SimulatorOperationRegistry: ObservableObject {
    static let shared = SimulatorOperationRegistry()

    enum Kind { case run, management, utility, display }

    struct Lease {
        let id: UUID
        let deviceID: UUID
        let kind: Kind
        let label: String
    }

    @Published private var leases: [UUID: Lease] = [:]
    private(set) var revision = 0
    private var deviceRevisions: [UUID: Int] = [:]

    func canAcquire(_ kind: Kind, on deviceID: UUID) -> Bool {
        switch kind {
        case .management: return !leases.values.contains { $0.deviceID == deviceID }
        case .run: return !leases.values.contains { $0.deviceID == deviceID && $0.kind == .management }
        case .utility:
            return !leases.values.contains { $0.deviceID == deviceID && ($0.kind == .management || $0.kind == .utility) }
        case .display:
            return !leases.values.contains { $0.deviceID == deviceID && ($0.kind == .management || $0.kind == .display) }
        }
    }

    func acquire(_ kind: Kind, on deviceID: UUID, label: String) -> Lease? {
        guard canAcquire(kind, on: deviceID) else { return nil }
        let lease = Lease(id: UUID(), deviceID: deviceID, kind: kind, label: label)
        invalidateInventory(on: deviceID)
        leases[lease.id] = lease
        return lease
    }

    func release(_ lease: Lease) {
        guard leases[lease.id] != nil else { return }
        invalidateInventory(on: lease.deviceID)
        leases.removeValue(forKey: lease.id)
    }

    func activity(on deviceID: UUID, runLabel: String?) -> String? {
        if let action = leases.values.first(where: {
            $0.deviceID == deviceID && ($0.kind == .management || $0.kind == .utility)
        }) {
            return action.label
        }
        if leases.values.contains(where: { $0.deviceID == deviceID && $0.kind == .run }) {
            return runLabel ?? "In use by SwiftDeck"
        }
        return isEmbedded(deviceID) ? "Embedded in SwiftDeck" : nil
    }

    func isEmbedded(_ deviceID: UUID) -> Bool {
        leases.values.contains { $0.deviceID == deviceID && $0.kind == .display }
    }

    func canManageAfterDetachingDisplay(on deviceID: UUID) -> Bool {
        isEmbedded(deviceID) && !leases.values.contains {
            $0.deviceID == deviceID && $0.kind != .display
        }
    }

    func revision(for deviceID: UUID) -> Int { deviceRevisions[deviceID, default: 0] }

    func invalidateInventory(on deviceID: UUID) {
        revision += 1
        deviceRevisions[deviceID] = revision
    }
}
