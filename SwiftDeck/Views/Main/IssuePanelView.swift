import SwiftUI

struct IssuePanelView: View {
    let issues: [BuildIssue]
    let status: ProjectStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Issues").font(.headline)
                Text("\(issues.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            ZStack {
                if issues.isEmpty {
                    EmptyIssuesView(status: status)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(issues) { issue in
                                HStack(alignment: .top, spacing: 12) {
                                    Label(issue.severity.rawValue.capitalized, systemImage: symbol(issue.severity))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(tint(issue.severity))
                                        .frame(width: 82, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(issue.message).textSelection(.enabled)
                                        Text("\(issue.file):\(issue.line)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 16)
                                .accessibilityElement(children: .combine)
                                Divider()
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
        }
        .animation(reduceMotion ? nil : DashboardMotion.content, value: issues.isEmpty)
    }

    private func symbol(_ severity: IssueSeverity) -> String {
        switch severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .note: "info.circle.fill"
        }
    }

    private func tint(_ severity: IssueSeverity) -> Color {
        switch severity {
        case .error: .red
        case .warning: .orange
        case .note: .blue
        }
    }
}

#Preview("Issues") {
    IssuePanelView(issues: [], status: .idle).frame(width: 650, height: 350)
}
