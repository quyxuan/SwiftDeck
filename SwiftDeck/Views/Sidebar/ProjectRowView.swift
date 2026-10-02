import SwiftUI

struct ProjectRowView: View, Equatable {
    let name: String
    let status: ProjectStatus
    let destination: String
    let iconRequest: ProjectIconRequest
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.status == rhs.status && lhs.destination == rhs.destination
            && lhs.iconRequest == rhs.iconRequest
    }

    var body: some View {
        HStack(spacing: 10) {
            ProjectIconView(request: iconRequest)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline).lineLimit(1)
                Text(destination).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            Image(systemName: status.symbol)
                .foregroundStyle(status.tint)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : DashboardMotion.content, value: status)
                .help(status.label)
        }
        .padding(.vertical, 7)
        .background(isHovered ? Color.primary.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : DashboardMotion.feedback, value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(destination), \(status.label)")
    }
}
