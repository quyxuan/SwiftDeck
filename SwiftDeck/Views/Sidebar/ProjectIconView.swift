import AppKit
import SwiftUI

struct ProjectIconView: View {
    let request: ProjectIconRequest

    @State private var image: NSImage?
    @State private var loadedRequest: ProjectIconRequest?
    @State private var revision: UInt64 = 0

    private struct LoadID: Equatable {
        let request: ProjectIconRequest
        let revision: UInt64
    }

    var body: some View {
        Group {
            if loadedRequest == request, let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "app.dashed")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
        .task(id: LoadID(request: request, revision: revision)) {
            let result = await ProjectIconStore.shared.image(for: request)
            guard !Task.isCancelled else { return }
            image = result
            loadedRequest = request
        }
        .onReceive(ProjectIconStore.shared.invalidations) { invalidated in
            guard invalidated == request else { return }
            revision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            ProjectIconStore.shared.refreshIfStale(request)
        }
    }
}
