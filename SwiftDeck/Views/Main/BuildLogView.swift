import SwiftUI

struct BuildLogView: View {
    @ObservedObject var store: ProjectLogStore
    @ObservedObject private var preferences = AppPreferences.shared
    @Binding var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followsOutput = true
    @State private var isUserScrolling = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Label("Build Log", systemImage: "terminal")
                    Spacer()
                    Text("\(store.entries.count) entries").foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse build log" : "Expand build log")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 9) {
                            if store.entries.isEmpty {
                                Text("Build activity will appear here.").foregroundStyle(.secondary)
                            }
                            ForEach(store.entries) { entry in
                                LogEntryView(entry: entry).equatable()
                                .id(entry.id)
                            }
                        }
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(16)
                    }
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 32
                    } action: { _, nearBottom in
                        if isUserScrolling, preferences.followBuildOutput { followsOutput = nearBottom }
                    }
                    .onScrollPhaseChange { _, phase in
                        isUserScrolling = phase == .interacting || phase == .decelerating
                    }
                    .onChange(of: store.entries.last?.id) { _, id in
                        if preferences.followBuildOutput, followsOutput, let id {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                    .onAppear {
                        followsOutput = preferences.followBuildOutput
                        if followsOutput, let id = store.entries.last?.id {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                    .onChange(of: preferences.followBuildOutput) { _, enabled in
                        followsOutput = enabled
                        if enabled, let id = store.entries.last?.id {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                    .transaction { $0.animation = nil }
                }
                .frame(height: 170)
                .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .background(.bar)
        .clipped()
        .animation(reduceMotion ? nil : DashboardMotion.expansion, value: isExpanded)
    }
}

private struct LogEntryView: View, Equatable {
    let entry: BuildLogEntry

    private var levelLabel: String {
        switch entry.level {
        case .info: "INFO"
        case .success: "SUCCESS"
        case .error: "ERROR"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .foregroundStyle(.secondary)
            Text(levelLabel)
                .foregroundStyle(entry.level == .error ? Color.red : Color.secondary)
                .frame(width: 58, alignment: .leading)
            Text(entry.message).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview("Expanded log") {
    BuildLogView(store: ProjectLogStore(), isExpanded: .constant(true))
        .frame(width: 700)
}
