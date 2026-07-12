import Testing
import Foundation
@testable import DownbenderCore

/// perform that emulates the DownloadCoordinator contract: an interruption honors the .paused set BEFORE the cancel.
@MainActor private func coordinatorLikePerform(workMilliseconds: Int = 5_000) -> @MainActor (DownloadItem) async -> Void {
    { item in
        do {
            try await Task.sleep(for: .milliseconds(workMilliseconds))
            item.state = .done
        } catch {
            if item.state != .paused { item.state = .cancelled }
        }
    }
}

@MainActor
@Test func pausingDownloadingItemKeepsItPausedAndFreesSlot() async {
    let vm = QueueViewModel(maxConcurrent: 1, perform: coordinatorLikePerform())
    let first = DownloadItem(url: "u1", title: "t1", format: .audioMP3, destination: URL(fileURLWithPath: "/tmp"))
    let second = DownloadItem(url: "u2", title: "t2", format: .audioMP3, destination: URL(fileURLWithPath: "/tmp"))
    vm.enqueue(first)
    vm.enqueue(second)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(first.state == .downloading)

    vm.pause(first)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(first.state == .paused)
    #expect(second.state == .downloading)
}

@MainActor
@Test func pausingQueuedItemPreventsItFromStarting() async {
    let vm = QueueViewModel(maxConcurrent: 1, perform: coordinatorLikePerform(workMilliseconds: 60))
    let first = DownloadItem(url: "u1", title: "t1", format: .audioMP3, destination: URL(fileURLWithPath: "/tmp"))
    let second = DownloadItem(url: "u2", title: "t2", format: .audioMP3, destination: URL(fileURLWithPath: "/tmp"))
    vm.enqueue(first)
    vm.enqueue(second)
    vm.pause(second)
    #expect(second.state == .paused)

    while first.state != .done { try? await Task.sleep(for: .milliseconds(10)) }
    try? await Task.sleep(for: .milliseconds(50))
    #expect(second.state == .paused)
}

@MainActor
@Test func resumingPausedItemRunsItToCompletion() async {
    let vm = QueueViewModel(maxConcurrent: 1, perform: coordinatorLikePerform(workMilliseconds: 40))
    let item = DownloadItem(url: "u", title: "t", format: .audioMP3, destination: URL(fileURLWithPath: "/tmp"))
    vm.add(item)
    item.state = .paused

    vm.resume(item)
    #expect(item.state == .queued || item.state == .downloading)
    while item.state != .done { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(item.state == .done)
}

@MainActor
@Test func retryRunsFailedItemAgainAndResetsProgress() async {
    let vm = QueueViewModel(maxConcurrent: 1, perform: coordinatorLikePerform(workMilliseconds: 40))
    let item = DownloadItem(url: "u", title: "t", format: .audioMP3, destination: URL(fileURLWithPath: "/tmp"))
    vm.add(item)
    item.state = .failed("boom")
    item.fraction = 0.7
    item.speedText = "1MiB/s"

    vm.retry(item)
    #expect(item.fraction == 0)
    #expect(item.speedText.isEmpty)
    while item.state != .done { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(item.state == .done)
}

@MainActor
@Test func cancellingPausedItemMarksItCancelled() async {
    let vm = QueueViewModel(maxConcurrent: 1, perform: coordinatorLikePerform())
    let item = DownloadItem(url: "u", title: "t", format: .audioMP3, destination: URL(fileURLWithPath: "/tmp"))
    vm.add(item)
    item.state = .paused

    vm.cancel(item)
    #expect(item.state == .cancelled)
}

// Pause→immediate-resume race: with the old Task still unwinding, pump() must not start a second
// process over the same .part files, nor may the old Task stomp the .queued with .cancelled.
@MainActor
@Test func resumingImmediatelyAfterPauseRunsOnceAndCompletes() async {
    let vm = QueueViewModel(maxConcurrent: 1, perform: { item in
        do {
            try await Task.sleep(for: .milliseconds(60))
            item.state = .done
        } catch {
            // finishInterrupted contract: it only overwrites execution states
            if item.state == .downloading || item.state == .merging { item.state = .cancelled }
        }
    })
    let item = DownloadItem(url: "u", title: "t", format: .audioMP3, destination: URL(fileURLWithPath: "/tmp"))
    vm.enqueue(item)
    try? await Task.sleep(for: .milliseconds(20))
    #expect(item.state == .downloading)

    vm.pause(item)
    vm.resume(item)   // without waiting for the previous Task to unwind
    #expect(item.state == .queued)   // waiting for the slot, NOT a second start

    var waited = 0
    while item.state != .done, waited < 300 {
        waited += 1
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(item.state == .done)   // neither .cancelled (stomped) nor stuck in .queued
}

/// Runner that hangs until cancelled: simulates yt-dlp mid-download when the user hits pause.
private struct HangingRunner: ProcessRunning {
    func run(
        executableURL: URL,
        arguments: [String],
        onStdoutLine: @Sendable @escaping (String) -> Void
    ) async throws -> ProcessResult {
        try await Task.sleep(for: .seconds(10))
        return ProcessResult(exitCode: 0, stderr: "")
    }
}

// The real pause contract: QueueViewModel sets .paused BEFORE cancelling the Task,
// and the DownloadCoordinator must honor it (not stomp it with .cancelled).
@MainActor
@Test func coordinatorKeepsPausedStateWhenInterruptedByPause() async {
    let download = DownloadService(runner: HangingRunner(), ytdlpURL: URL(fileURLWithPath: "/x"), ffmpegDirectory: URL(fileURLWithPath: "/y"))
    let coordinator = DownloadCoordinator(download: download)
    let item = DownloadItem(url: "u", title: "t", format: .video(height: 1080), destination: URL(fileURLWithPath: "/tmp"))

    let task = Task {
        await coordinator.run(item, tmpDirectory: URL(fileURLWithPath: "/tmp/work"))
    }
    try? await Task.sleep(for: .milliseconds(50))
    item.state = .paused    // exact order of QueueViewModel.pause
    task.cancel()
    await task.value
    #expect(item.state == .paused)
}

@MainActor
@Test func startRequiresChosenFormat() async {
    let vm = QueueViewModel(maxConcurrent: 1, perform: coordinatorLikePerform())
    let item = DownloadItem(url: "u", title: "t", destination: URL(fileURLWithPath: "/tmp"), state: .readyToChoose)
    vm.add(item)

    vm.start(item)
    #expect(item.state == .readyToChoose)

    item.format = .audioMP3
    vm.start(item)
    #expect(item.state == .queued || item.state == .downloading)
}
