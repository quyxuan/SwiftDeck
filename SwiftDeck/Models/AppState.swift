import Foundation

enum ProjectStatus: String, CaseIterable, Sendable {
    case idle
    case building
    case running
    case stopped
    case failed
}

enum SimulatorStatus: String, CaseIterable, Sendable {
    case available
    case booted
    case booting
    case shuttingDown
    case unavailable

    var displayLabel: String {
        switch self {
        case .available: "Shut Down"
        case .booted: "Booted"
        case .booting: "Booting"
        case .shuttingDown: "Shutting Down"
        case .unavailable: "Unavailable"
        }
    }
}

enum IssueSeverity: String, CaseIterable, Sendable {
    case error
    case warning
    case note
}

enum LogLevel: String, CaseIterable, Sendable {
    case info
    case success
    case error
}
