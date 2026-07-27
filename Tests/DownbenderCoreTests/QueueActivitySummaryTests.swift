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
@Test func queueActivitySnapshotQuantizesProgressAndPreservesCounts() {
    let items: [DownloadItem] = [
        makeItem(.downloading, fraction: 0.504),
        makeItem(.queued, fraction: 0.504),
        makeItem(.paused),
        makeItem(.failed("download")),
    ]

    let snapshot = QueueActivitySnapshot(items: items)

    #expect(snapshot.runningCount == 1)
    #expect(snapshot.queuedCount == 1)
    #expect(snapshot.pausedCount == 1)
    #expect(snapshot.failedCount == 1)
    #expect(snapshot.activeCount == 2)
    #expect(snapshot.progressPercent == 50)
}

@MainActor
@Test func queueActivitySnapshotEqualityIgnoresRawProgressInsideOnePercentBucket() {
    let item = makeItem(.downloading, fraction: 0.501)
    let first = QueueActivitySnapshot(items: [item])

    item.fraction = 0.504
    let sameVisibleProgress = QueueActivitySnapshot(items: [item])
    #expect(sameVisibleProgress == first)

    item.fraction = 0.506
    let nextVisibleProgress = QueueActivitySnapshot(items: [item])
    #expect(nextVisibleProgress != first)
    #expect(nextVisibleProgress.progressPercent == 51)
}

@MainActor
@Test func queueActivitySnapshotKeepsIndeterminateProgressUnknown() {
    let item = makeItem(.downloading, fraction: 0.75)
    item.indeterminateProgress = true

    #expect(QueueActivitySnapshot(items: [item]).progressPercent == nil)
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
