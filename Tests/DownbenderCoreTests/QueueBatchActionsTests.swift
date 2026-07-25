import Foundation
import Testing
@testable import DownbenderCore

@MainActor
private func batchItem(
    _ name: String,
    state: DownloadItem.State
) -> DownloadItem {
    DownloadItem(
        url: "https://example.com/\(name)",
        title: name,
        format: .audioMP3,
        destination: URL(fileURLWithPath: "/tmp"),
        state: state
    )
}

@MainActor
@Test func queueBatchActionCountsReflectMixedQueueStates() {
    let queue = QueueViewModel(maxConcurrent: 0, perform: { _ in })
    let states: [DownloadItem.State] = [
        .probing,
        .probeFailed("probe failed"),
        .readyToChoose,
        .queued,
        .downloading,
        .merging,
        .paused,
        .done,
        .failed("download failed"),
        .cancelled,
    ]

    for (index, state) in states.enumerated() {
        queue.add(batchItem("item-\(index)", state: state))
    }

    #expect(queue.pausableCount == 3)
    #expect(queue.resumableCount == 1)
    #expect(queue.cancellableCount == 4)
}

@MainActor
@Test func queueBatchPauseAllPausesEveryEligibleStateAndNotifiesOnce() {
    let queue = QueueViewModel(maxConcurrent: 0, perform: { _ in })
    let queued = batchItem("queued", state: .queued)
    let downloading = batchItem("downloading", state: .downloading)
    let merging = batchItem("merging", state: .merging)
    let alreadyPaused = batchItem("paused", state: .paused)
    let chooser = batchItem("chooser", state: .readyToChoose)
    for item in [queued, downloading, merging, alreadyPaused, chooser] {
        queue.add(item)
    }

    var mutationCount = 0
    queue.onMutation = { mutationCount += 1 }

    #expect(queue.pauseAllActive() == 3)
    #expect(mutationCount == 1)
    #expect(queued.state == .paused)
    #expect(downloading.state == .paused)
    #expect(merging.state == .paused)
    #expect(alreadyPaused.state == .paused)
    #expect(chooser.state == .readyToChoose)

    #expect(queue.pauseAllActive() == 0)
    #expect(mutationCount == 1)
}

@MainActor
@Test func queueBatchResumeAllClearsTransientTextAndHonorsConcurrency() async {
    var current = 0
    var maximumSeen = 0
    let queue = QueueViewModel(maxConcurrent: 2, perform: { item in
        current += 1
        maximumSeen = max(maximumSeen, current)
        try? await Task.sleep(for: .milliseconds(30))
        current -= 1
        item.state = .done
    })

    let items = (0..<4).map { index in
        let item = batchItem("paused-\(index)", state: .paused)
        item.speedText = "\(index + 1) MiB/s"
        item.etaText = "\(index + 1)s"
        queue.add(item)
        return item
    }

    #expect(queue.resumeAllPaused() == 4)
    #expect(items.allSatisfy { $0.speedText.isEmpty && $0.etaText.isEmpty })
    #expect(items.filter { $0.state == .downloading }.count == 2)
    #expect(items.filter { $0.state == .queued }.count == 2)

    var attempts = 0
    while items.contains(where: { $0.state != .done }), attempts < 200 {
        attempts += 1
        try? await Task.sleep(for: .milliseconds(5))
    }

    #expect(items.allSatisfy { $0.state == .done })
    #expect(maximumSeen == 2)
}

@MainActor
@Test func queueBatchCancelAllStopsActiveWorkAndNeverStartsQueuedItems() async {
    var startedURLs: [String] = []
    let queue = QueueViewModel(maxConcurrent: 2, perform: { item in
        startedURLs.append(item.url)
        if item.title == "merging" {
            item.state = .merging
        }
        do {
            try await Task.sleep(for: .seconds(5))
            item.state = .done
        } catch {
            if item.state == .downloading || item.state == .merging {
                item.state = .cancelled
            }
        }
    })

    let downloading = batchItem("downloading", state: .queued)
    let merging = batchItem("merging", state: .queued)
    let waiting = batchItem("waiting", state: .queued)
    queue.enqueue(downloading)
    queue.enqueue(merging)
    queue.enqueue(waiting)

    let pausedDirect = batchItem("paused-direct", state: .paused)
    pausedDirect.source = .directFile(DirectFileInfo(suggestedName: "paused.bin"))
    pausedDirect.resumeData = Data("resume-data".utf8)

    let probing = batchItem("probing", state: .probing)
    let probeFailed = batchItem("probe-failed", state: .probeFailed("still failed"))
    let chooser = batchItem("chooser", state: .readyToChoose)
    let done = batchItem("done", state: .done)
    let failed = batchItem("failed", state: .failed("still failed"))
    let previouslyCancelled = batchItem("previously-cancelled", state: .cancelled)
    for item in [pausedDirect, probing, probeFailed, chooser, done, failed, previouslyCancelled] {
        queue.add(item)
    }

    var attempts = 0
    while startedURLs.count < 2 || merging.state != .merging, attempts < 200 {
        attempts += 1
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(startedURLs.count == 2)
    #expect(waiting.state == .queued)
    #expect(queue.cancellableCount == 4)

    #expect(queue.cancelAll() == 4)
    #expect(waiting.state == .cancelled)
    #expect(pausedDirect.state == .cancelled)
    #expect(pausedDirect.resumeData == nil)

    attempts = 0
    while queue.hasLiveTasks, attempts < 200 {
        attempts += 1
        try? await Task.sleep(for: .milliseconds(5))
    }

    #expect(!queue.hasLiveTasks)
    #expect(downloading.state == .cancelled)
    #expect(merging.state == .cancelled)
    #expect(!startedURLs.contains(waiting.url))
    #expect(startedURLs.count == 2)

    #expect(probing.state == .probing)
    #expect(probeFailed.state == .probeFailed("still failed"))
    #expect(chooser.state == .readyToChoose)
    #expect(done.state == .done)
    #expect(failed.state == .failed("still failed"))
    #expect(previouslyCancelled.state == .cancelled)
    #expect(queue.items.count == 10)
}
