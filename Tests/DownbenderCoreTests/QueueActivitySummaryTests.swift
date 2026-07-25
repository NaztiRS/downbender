import Testing
import Foundation
@testable import DownbenderCore

@MainActor
@Test func queueActivitySummaryCountsEveryStateAndAveragesActiveProgress() {
    let items: [DownloadItem] = [
        makeItem(.probing),
        makeItem(.probeFailed("probe")),
        makeItem(.readyToChoose),
        makeItem(.queued, fraction: 0),
        makeItem(.downloading, fraction: 0.5),
        makeItem(.merging, fraction: 1),
        makeItem(.paused, fraction: 0.2),
        makeItem(.done),
        makeItem(.failed("download")),
        makeItem(.cancelled),
    ]

    let summary = QueueActivitySummary(items: items)

    #expect(summary.analyzingCount == 1)
    #expect(summary.choosingCount == 1)
    #expect(summary.runningCount == 2)
    #expect(summary.queuedCount == 1)
    #expect(summary.pausedCount == 1)
    #expect(summary.completedCount == 1)
    #expect(summary.failedCount == 2)
    #expect(summary.cancelledCount == 1)
    #expect(summary.activeCount == 3)
    #expect(summary.pendingCount == 6)
    #expect(summary.totalCount == 10)
    #expect(summary.progressFraction == 0.5)
}

@MainActor
@Test func queueActivitySummaryOmitsProgressForIndeterminateOrInactiveWork() {
    let indeterminate = makeItem(.downloading, fraction: 0.4)
    indeterminate.indeterminateProgress = true
    #expect(QueueActivitySummary(items: [indeterminate]).progressFraction == nil)

    let paused = makeItem(.paused, fraction: 0.75)
    #expect(QueueActivitySummary(items: [paused]).progressFraction == nil)
}

@MainActor
@Test func queueActivitySummaryClampsFractionsBeforeAveraging() {
    let summary = QueueActivitySummary(items: [
        makeItem(.downloading, fraction: -2),
        makeItem(.queued, fraction: 3),
    ])

    #expect(summary.progressFraction == 0.5)
}

@MainActor
private func makeItem(_ state: DownloadItem.State, fraction: Double = 0) -> DownloadItem {
    let item = DownloadItem(
        url: "https://example.com/file",
        title: "File",
        destination: URL(fileURLWithPath: "/tmp"),
        state: state
    )
    item.fraction = fraction
    return item
}
