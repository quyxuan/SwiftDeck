import Combine
import Foundation

/// Value snapshots share immutable pages, not a 5,000-element contiguous buffer.
/// Appending after publication copies only the page table and the current 128-entry page.
struct BoundedEntries<Element: Sendable>: RandomAccessCollection, Sendable {
    typealias Index = Int
    private static var pageSize: Int { 128 }
    private var pages: [Int: [Element]] = [:]
    private let limit: Int
    private(set) var startIndex = 0
    private(set) var endIndex = 0

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    subscript(index: Int) -> Element {
        precondition(index >= startIndex && index < endIndex)
        return pages[index / Self.pageSize]![index % Self.pageSize]
    }

    func index(after index: Int) -> Int { index + 1 }
    func index(before index: Int) -> Int { index - 1 }
    func index(_ index: Int, offsetBy distance: Int) -> Int { index + distance }
    func distance(from start: Int, to end: Int) -> Int { end - start }

    mutating func append(_ element: Element) {
        let page = endIndex / Self.pageSize
        if pages[page] == nil {
            var entries: [Element] = []
            entries.reserveCapacity(Self.pageSize)
            pages[page] = entries
        }
        pages[page]!.append(element)
        endIndex += 1
        if endIndex - startIndex > limit {
            let expiredPage = startIndex / Self.pageSize
            startIndex += 1
            if startIndex / Self.pageSize != expiredPage {
                pages.removeValue(forKey: expiredPage)
            }
        }
    }
}

@MainActor
final class ProjectLogStore: ObservableObject {
    @Published private(set) var entries = BoundedEntries<BuildLogEntry>(limit: 5_000)
    private var bufferedEntries = BoundedEntries<BuildLogEntry>(limit: 5_000)

    func append(_ entry: BuildLogEntry) {
        bufferedEntries.append(entry)
    }

    func flush() {
        guard entries.endIndex != bufferedEntries.endIndex else { return }
        entries = bufferedEntries
    }
}
