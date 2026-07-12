import Testing
import Foundation
@testable import DownbenderCore

@MainActor
@Test func coordinatorMarksDoneAndUpdatesProgress() async {
    let runner = FakeProcessRunner(stdoutLines: ["DBPROG 50.0% 50000000 100000000 1MiB/s 00:10"], exitCode: 0)
    let download = DownloadService(runner: runner, ytdlpURL: URL(fileURLWithPath: "/x"), ffmpegDirectory: URL(fileURLWithPath: "/y"))
    let coordinator = DownloadCoordinator(download: download)
    let item = DownloadItem(url: "u", title: "t", format: .video(height: 1080), destination: URL(fileURLWithPath: "/tmp"))
    item.expectedTotalBytes = 100_000_000

    await coordinator.run(item, tmpDirectory: URL(fileURLWithPath: "/tmp/work"))
    #expect(item.state == .done)
    #expect(abs(item.fraction - 0.5) < 0.0001)
}

@MainActor
@Test func coordinatorMarksFailedOnError() async {
    let runner = FakeProcessRunner(stderr: "ERROR boom", exitCode: 1)
    let download = DownloadService(runner: runner, ytdlpURL: URL(fileURLWithPath: "/x"), ffmpegDirectory: URL(fileURLWithPath: "/y"))
    let coordinator = DownloadCoordinator(download: download)
    let item = DownloadItem(url: "u", title: "t", format: .audioMP3, destination: URL(fileURLWithPath: "/tmp"))

    await coordinator.run(item, tmpDirectory: URL(fileURLWithPath: "/tmp/work"))
    if case .failed = item.state {} else { Issue.record("expected .failed, got \(item.state)") }
}

@MainActor
@Test func coordinatorRecordsDeliveredNoteWhenDimensionsMatch() async {
    let runner = FakeProcessRunner(stdoutLines: [
        "DBPROG 100.0% 2MiB/s 00:00",
        "DBPATH /tmp/out/video.mp4",
    ], exitCode: 0)
    let download = DownloadService(runner: runner, ytdlpURL: URL(fileURLWithPath: "/x"), ffmpegDirectory: URL(fileURLWithPath: "/y"))
    let coordinator = DownloadCoordinator(download: download, inspect: { _ in (width: 1920, height: 1080) })
    let item = DownloadItem(url: "u", title: "t", format: .video(height: 1080), destination: URL(fileURLWithPath: "/tmp"))

    await coordinator.run(item, tmpDirectory: URL(fileURLWithPath: "/tmp/work"))
    #expect(item.state == .done)
    #expect(item.deliveredNote == "1920×1080")
    #expect(item.deliveredMismatch == false)
    #expect(item.deliveredFileURL == URL(fileURLWithPath: "/tmp/out/video.mp4"))
}

@MainActor
@Test func coordinatorRecordsMismatchWhenDeliveredHeightDiffers() async {
    let runner = FakeProcessRunner(stdoutLines: [
        "DBPROG 100.0% 2MiB/s 00:00",
        "DBPATH /tmp/out/video.mp4",
    ], exitCode: 0)
    let download = DownloadService(runner: runner, ytdlpURL: URL(fileURLWithPath: "/x"), ffmpegDirectory: URL(fileURLWithPath: "/y"))
    let coordinator = DownloadCoordinator(download: download, inspect: { _ in (width: 1280, height: 720) })
    let item = DownloadItem(url: "u", title: "t", format: .video(height: 1080), destination: URL(fileURLWithPath: "/tmp"))

    await coordinator.run(item, tmpDirectory: URL(fileURLWithPath: "/tmp/work"))
    #expect(item.state == .done)
    #expect(item.deliveredNote == "Requested 1080p, got 720p")
    #expect(item.deliveredMismatch == true)
}

// The ffprobe verification adds a suspension point after the download: a cancel while it
// runs (inspect returns nil without propagating the error) must end in .cancelled, not .done.
@MainActor
@Test func coordinatorMarksCancelledWhenCancelledDuringInspection() async {
    let runner = FakeProcessRunner(stdoutLines: [
        "DBPROG 100.0% 2MiB/s 00:00",
        "DBPATH /tmp/out/v.mp4",
    ], exitCode: 0)
    let download = DownloadService(runner: runner, ytdlpURL: URL(fileURLWithPath: "/x"), ffmpegDirectory: URL(fileURLWithPath: "/y"))
    let coordinator = DownloadCoordinator(download: download, inspect: { _ in
        try? await Task.sleep(for: .seconds(5))
        return nil
    })
    let item = DownloadItem(url: "u", title: "t", format: .video(height: 1080), destination: URL(fileURLWithPath: "/tmp"))

    let task = Task {
        await coordinator.run(item, tmpDirectory: URL(fileURLWithPath: "/tmp/work"))
    }
    try? await Task.sleep(for: .milliseconds(50))
    task.cancel()
    await task.value
    #expect(item.state == .cancelled)
}

// YouTube 403s are intermittent: a fresh yt-dlp invocation renegotiates the signed URLs.

@MainActor
@Test func coordinatorRetriesOn403UpToThreeAttemptsThenFails() async {
    let runner = FakeProcessRunner(stderr: "HTTP Error 403: Forbidden", exitCode: 1)
    let download = DownloadService(runner: runner, ytdlpURL: URL(fileURLWithPath: "/x"), ffmpegDirectory: URL(fileURLWithPath: "/y"))
    let coordinator = DownloadCoordinator(download: download, retryDelay: .milliseconds(10))
    let item = DownloadItem(url: "u", title: "t", format: .video(height: 1080), destination: URL(fileURLWithPath: "/tmp"))

    await coordinator.run(item, tmpDirectory: URL(fileURLWithPath: "/tmp/work"))
    #expect(runner.calls.count == 3)
    if case .failed = item.state {} else { Issue.record("expected .failed, got \(item.state)") }
}

@MainActor
@Test func coordinatorRecoversWhen403ClearsOnRetry() async {
    let runner = FakeProcessRunner(replays: [
        .init(stderr: "HTTP Error 403: Forbidden", exitCode: 1),
        .init(stdoutLines: [
            "DBPROG 100.0% 2MiB/s 00:00",
            "DBPATH /tmp/out/video.mp4",
        ], exitCode: 0),
    ])
    let download = DownloadService(runner: runner, ytdlpURL: URL(fileURLWithPath: "/x"), ffmpegDirectory: URL(fileURLWithPath: "/y"))
    let coordinator = DownloadCoordinator(download: download, retryDelay: .milliseconds(10))
    let item = DownloadItem(url: "u", title: "t", format: .video(height: 1080), destination: URL(fileURLWithPath: "/tmp"))

    await coordinator.run(item, tmpDirectory: URL(fileURLWithPath: "/tmp/work"))
    #expect(runner.calls.count == 2)
    #expect(item.state == .done)
}

// If the failed attempt reached .merging before the 403, the retry must go back to .downloading:
// the hop guards (`if state == .downloading`) would otherwise silently discard all of its progress.
@MainActor
@Test func coordinatorResetsStateToDownloadingOnRetryAfterMerging() async {
    let runner = FakeProcessRunner(replays: [
        .init(stdoutLines: ["[Merger] Merging formats into \"/tmp/out/video.mp4\""], stderr: "HTTP Error 403: Forbidden", exitCode: 1),
        .init(stdoutLines: [
            "DBPROG 50.0% 50000000 100000000 1MiB/s 00:10",
            "DBPATH /tmp/out/video.mp4",
        ], exitCode: 0),
    ])
    let download = DownloadService(runner: runner, ytdlpURL: URL(fileURLWithPath: "/x"), ffmpegDirectory: URL(fileURLWithPath: "/y"))
    let coordinator = DownloadCoordinator(download: download, retryDelay: .milliseconds(10))
    let item = DownloadItem(url: "u", title: "t", format: .video(height: 1080), destination: URL(fileURLWithPath: "/tmp"))
    item.expectedTotalBytes = 100_000_000

    await coordinator.run(item, tmpDirectory: URL(fileURLWithPath: "/tmp/work"))
    #expect(item.state == .done)
    #expect(abs(item.fraction - 0.5) < 0.0001)
}

// Attempts 1-2 go without the TV client (cures transient 403s); the FINAL attempt
// adds player_client=tv to dodge the persistent PO-token shielding.
@MainActor
@Test func coordinatorEscalatesToTVClientOnFinalAttempt() async {
    let runner = FakeProcessRunner(replays: [
        .init(stderr: "HTTP Error 403: Forbidden", exitCode: 1),
        .init(stderr: "HTTP Error 403: Forbidden", exitCode: 1),
        .init(stdoutLines: [
            "DBPROG 100.0% 2MiB/s 00:00",
            "DBPATH /tmp/out/video.mp4",
        ], exitCode: 0),
    ])
    let download = DownloadService(runner: runner, ytdlpURL: URL(fileURLWithPath: "/x"), ffmpegDirectory: URL(fileURLWithPath: "/y"))
    let coordinator = DownloadCoordinator(download: download, retryDelay: .milliseconds(10))
    let item = DownloadItem(url: "u", title: "t", format: .video(height: 1080), destination: URL(fileURLWithPath: "/tmp"))

    await coordinator.run(item, tmpDirectory: URL(fileURLWithPath: "/tmp/work"))
    #expect(item.state == .done)

    let perCall = runner.recordedArguments.allArguments
    guard perCall.count == 3 else {
        Issue.record("expected 3 invocations, got \(perCall.count)")
        return
    }
    #expect(!perCall[0].contains("youtube:player_client=tv"))
    #expect(!perCall[1].contains("youtube:player_client=tv"))
    #expect(perCall[2].contains("youtube:player_client=tv"))
}

@MainActor
@Test func coordinatorDoesNotRetryNon403Errors() async {
    let runner = FakeProcessRunner(stderr: "ERROR: Video unavailable", exitCode: 1)
    let download = DownloadService(runner: runner, ytdlpURL: URL(fileURLWithPath: "/x"), ffmpegDirectory: URL(fileURLWithPath: "/y"))
    let coordinator = DownloadCoordinator(download: download, retryDelay: .milliseconds(10))
    let item = DownloadItem(url: "u", title: "t", format: .video(height: 1080), destination: URL(fileURLWithPath: "/tmp"))

    await coordinator.run(item, tmpDirectory: URL(fileURLWithPath: "/tmp/work"))
    #expect(runner.calls.count == 1)
    if case .failed = item.state {} else { Issue.record("expected .failed, got \(item.state)") }
}

@MainActor
@Test func runPassesCookiesBrowserToYtdlp() async {
    let runner = FakeProcessRunner(stdoutLines: ["DBPATH /tmp/out.mp3"], exitCode: 0)
    let download = DownloadService(runner: runner, ytdlpURL: URL(fileURLWithPath: "/x"), ffmpegDirectory: URL(fileURLWithPath: "/y"))
    let coordinator = DownloadCoordinator(download: download)
    let item = DownloadItem(url: "u", title: "t", format: .audioMP3, destination: URL(fileURLWithPath: "/tmp"))

    await coordinator.run(item, tmpDirectory: URL(fileURLWithPath: "/tmp/work"), cookiesBrowser: "brave")
    let args = runner.recordedArguments.arguments
    #expect(args.contains("--cookies-from-browser"))
    #expect(args.contains("brave"))
}
