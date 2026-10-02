import SwiftUI

extension ProjectStatus {
    var label: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .idle: "checkmark.circle"
        case .building: "hammer.circle"
        case .running: "play.circle.fill"
        case .stopped: "stop.circle"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .idle: .secondary
        case .building: .orange
        case .running: .green
        case .stopped: .secondary
        case .failed: .red
        }
    }
}

struct StatusBadgeView: View {
    let status: ProjectStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label(status.label, systemImage: status.symbol)
            .font(.callout.weight(.medium))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(status.tint.opacity(0.1), in: Capsule())
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : DashboardMotion.content, value: status)
            .accessibilityLabel("Status: \(status.label)")
    }
}
