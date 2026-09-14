/// The status groups exposed by the queue's visualization controls.
public enum QueueFilter: String, CaseIterable, Hashable, Sendable {
    case active
    case paused
    case complete
    case failed

    @MainActor
    public func matches(_ item: DownloadItem) -> Bool {
        switch (self, item.state) {
        case (.active, .queued), (.active, .downloading), (.active, .merging),
             (.paused, .paused), (.complete, .done),
             (.failed, .probeFailed), (.failed, .failed):
            true
        default:
            false
        }
    }
}

@MainActor
public func filteredQueueItems(
    _ items: [DownloadItem],
    filters: Set<QueueFilter>
) -> [DownloadItem] {
    guard !filters.isEmpty else { return items }
    return items.filter { item in filters.contains { $0.matches(item) } }
}
