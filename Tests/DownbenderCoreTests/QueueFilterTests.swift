import Foundation
import Testing
@testable import DownbenderCore

@MainActor
@Test func queueFiltersCombineSelectedStatesAndShowEverythingWhenEmpty() {
    let probing = filterItem("probing", state: .probing)
    let queued = filterItem("queued", state: .queued)
    let downloading = filterItem("downloading", state: .downloading)
    let merging = filterItem("merging", state: .merging)
    let paused = filterItem("paused", state: .paused)
    let complete = filterItem("complete", state: .done)
    let probeFailure = filterItem("probe-failure", state: .probeFailed("boom"))
    let downloadFailure = filterItem("download-failure", state: .failed("boom"))
    let cancelled = filterItem("cancelled", state: .cancelled)
    let items = [
        probing, queued, downloading, merging, paused, complete,
        probeFailure, downloadFailure, cancelled,
    ]

    #expect(filteredQueueItems(items, filters: []).map(\.id) == items.map(\.id))
    #expect(
        filteredQueueItems(items, filters: [.active]).map(\.id)
            == [queued.id, downloading.id, merging.id]
    )
    #expect(filteredQueueItems(items, filters: [.paused]).map(\.id) == [paused.id])
    #expect(filteredQueueItems(items, filters: [.complete]).map(\.id) == [complete.id])
    #expect(
        filteredQueueItems(items, filters: [.failed]).map(\.id)
            == [probeFailure.id, downloadFailure.id]
    )

    let visible = filteredQueueItems(items, filters: [.active, .paused, .complete, .failed])
    let visibleIDs: [UUID] = visible.map(\.id)
    let expectedIDs: [UUID] = [
        queued.id, downloading.id, merging.id, paused.id, complete.id,
        probeFailure.id, downloadFailure.id,
    ]
    #expect(visibleIDs == expectedIDs)
}

@MainActor
private func filterItem(_ title: String, state: DownloadItem.State) -> DownloadItem {
    DownloadItem(
        url: "https://example.com/\(title)",
        title: title,
        destination: URL(fileURLWithPath: "/tmp"),
        state: state
    )
}
