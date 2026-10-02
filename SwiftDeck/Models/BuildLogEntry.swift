import Foundation

struct BuildLogEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    var timestamp: Date
    var level: LogLevel
    var message: String

    init(id: UUID = UUID(), timestamp: Date = Date(), level: LogLevel, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}
