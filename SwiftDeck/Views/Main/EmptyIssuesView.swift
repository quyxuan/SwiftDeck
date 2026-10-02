import SwiftUI

struct EmptyIssuesView: View {
    let status: ProjectStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: status == .failed ? "exclamationmark.triangle" : "text.magnifyingglass")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text(status == .failed ? "Operation failed" : "No reported diagnostics")
                .font(.title3.weight(.semibold))
            Text(status == .failed
                 ? "The tool did not report a source diagnostic. Check the build log for details."
                 : "Compiler diagnostics appear here as the selected project builds.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .contentTransition(.opacity)
        .animation(reduceMotion ? nil : DashboardMotion.content, value: status == .failed)
    }
}

#Preview("Empty issues") { EmptyIssuesView(status: .idle) }
