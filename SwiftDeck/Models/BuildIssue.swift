import Foundation

struct BuildIssue: Identifiable, Equatable, Sendable {
    let id: UUID
    var severity: IssueSeverity
    var message: String
    var file: String
    var line: Int

    init(id: UUID = UUID(), severity: IssueSeverity, message: String, file: String, line: Int) {
        self.id = id
        self.severity = severity
        self.message = message
        self.file = file
        self.line = line
    }

    /// Xcode/Swift/Clang source diagnostics, preserving paths containing spaces or colons.
    static func parse(_ line: String) -> BuildIssue? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = diagnosticPattern.firstMatch(in: line, range: range),
              let fileRange = Range(match.range(at: 1), in: line),
              let lineRange = Range(match.range(at: 2), in: line),
              let severityRange = Range(match.range(at: 3), in: line),
              let messageRange = Range(match.range(at: 4), in: line),
              let lineNumber = Int(line[lineRange]),
              let severity = IssueSeverity(rawValue: String(line[severityRange])) else { return nil }
        return BuildIssue(
            severity: severity, message: String(line[messageRange]),
            file: String(line[fileRange]), line: lineNumber
        )
    }

    private static let diagnosticPattern = try! NSRegularExpression(
        pattern: #"^(.+?):(\d+):(?:\d+:)?\s*(error|warning|note):\s*(.*)$"#
    )
}
