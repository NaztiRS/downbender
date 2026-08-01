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
    #expect(item.fraction == 1)
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

@MainActor
@Test func coordinatorRecordsMaximumDimensionsWithoutMismatch() async {
    let runner = FakeProcessRunner(stdoutLines: [
        "DBPROG 100.0% 2MiB/s 00:00",
        "DBPATH /tmp/out/video.mkv",
    ], exitCode: 0)
    let download = DownloadService(
        runner: runner,
        ytdlpURL: URL(fileURLWithPath: "/x"),
        ffmpegDirectory: URL(fileURLWithPath: "/y")
    )
    let coordinator = DownloadCoordinator(
        download: download,
        inspect: { _ in (width: 3840, height: 2160) }
    )
    let item = DownloadItem(
        url: "u",
        title: "t",
        format: .maximumVideo,
        destination: URL(fileURLWithPath: "/tmp")
    )

    await coordinator.run(item, tmpDirectory: URL(fileURLWithPath: "/tmp/work"))

    #expect(item.state == .done)
    #expect(item.deliveredNote == "3840×2160")
    #expect(item.deliveredMismatch == false)
    #expect(item.deliveredFileURL == URL(fileURLWithPath: "/tmp/out/video.mkv"))
}

@MainActor
@Test func coordinatorNeverInspectsDimensionsForAudioOutputs() async {
    let inspections = CallCounter()

    for format in DownloadFormat.audioFormats {
        let path = "/tmp/out/track.\(format.id)"
        let runner = FakeProcessRunner(stdoutLines: ["DBPATH \(path)"], exitCode: 0)
        let download = DownloadService(
            runner: runner,
            ytdlpURL: URL(fileURLWithPath: "/x"),
            ffmpegDirectory: URL(fileURLWithPath: "/y")
        )
        let coordinator = DownloadCoordinator(download: download, inspect: { _ in
            _ = inspections.next()
            return (width: 1, height: 1)
        })
        let item = DownloadItem(
            url: "u",
            title: format.label,
            format: format,
            destination: URL(fileURLWithPath: "/tmp")
        )

        await coordinator.run(item, tmpDirectory: URL(fileURLWithPath: "/tmp/work"))

        #expect(item.state == .done)
        #expect(item.deliveredFileURL?.path == path)
        #expect(item.deliveredNote.isEmpty)
    }

    #expect(inspections.count < 1)
}

@MainActor
@Test func coordinatorForcesFinalFractionAfterEnteringMergingState() async {
    let gate = ProgressTestGate()
    let runner = FakeProcessRunner(
        stdoutLines: [
            "DBPROG 40.0% 40000000 100000000 1MiB/s 00:10",
            "[Merger] Merging formats into \"/tmp/out/video.mp4\"",
        ],
        beforeReturn: { call in
            if call == 0 { await gate.wait() }
        }
    )
    let download = DownloadService(
        runner: runner,
        ytdlpURL: URL(fileURLWithPath: "/x"),
        ffmpegDirectory: URL(fileURLWithPath: "/y")
    )
    let coordinator = DownloadCoordinator(download: download)
    let item = DownloadItem(
        url: "u",
        title: "t",
        format: .video(height: 1080),
        destination: URL(fileURLWithPath: "/tmp")
    )
    item.expectedTotalBytes = 100_000_000

    let run = Task {
        await coordinator.run(item, tmpDirectory: URL(fileURLWithPath: "/tmp/work"))
    }
    #expect(await waitForProgressCondition { item.state == .merging })
    #expect(item.fraction < 1)

    await gate.open()
    await run.value
    #expect(item.state == .done)
    #expect(item.fraction == 1)
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
    #expect(item.failureDiagnostics?.attempts.count == 3)
    #expect(item.failureDiagnostics?.attempts.map(\.number) == [1, 2, 3])
    #expect(item.failureDiagnostics?.attempts.allSatisfy { !$0.detailed } == true)
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
    #expect(item.failureDiagnostics == nil)
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
    #expect(item.fraction == 1)
}

@MainActor
@Test func coordinatorRetryCancelsBufferedProgressFromFailedAttempt() async {
    let gate = ProgressTestGate()
    let sleeper = ManualProgressSleeper()
    let runner = FakeProcessRunner(
        replays: [
            .init(stdoutLines: [
                "DBPROG 10.0% 10000000 100000000 1MiB/s 00:20",
                "DBPROG 90.0% 90000000 100000000 1MiB/s 00:02",
            ], stderr: "HTTP Error 403: Forbidden", exitCode: 1),
            .init(exitCode: 0),
        ],
        beforeReturn: { call in
            if call == 1 { await gate.wait() }
        }
    )
    let download = DownloadService(
        runner: runner,
        ytdlpURL: URL(fileURLWithPath: "/x"),
        ffmpegDirectory: URL(fileURLWithPath: "/y")
    )
    let coordinator = DownloadCoordinator(
        download: download,
        retryDelay: .zero,
        progressInterval: .milliseconds(250),
        progressSleep: { duration in await sleeper.sleep(for: duration) }
    )
    let item = DownloadItem(
        url: "u",
        title: "t",
        format: .audioMP3,
        destination: URL(fileURLWithPath: "/tmp")
    )

    let run = Task {
        await coordinator.run(item, tmpDirectory: URL(fileURLWithPath: "/tmp/work"))
    }
    #expect(await waitForProgressCondition {
        runner.calls.count == 2 && item.state == .downloading
    })
    #expect(item.fraction == 0)

    sleeper.advanceAll()
    for _ in 0..<20 { await Task.yield() }
    #expect(item.fraction == 0)

    await gate.open()
    await run.value
    #expect(item.state == .done)
    #expect(item.fraction == 1)
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
@Test func coordinatorKeepsItemsFileNameTemplateAcrossRetries() async {
    let runner = FakeProcessRunner(replays: [
        .init(stderr: "HTTP Error 403: Forbidden", exitCode: 1),
        .init(stderr: "HTTP Error 403: Forbidden", exitCode: 1),
        .init(stdoutLines: ["DBPATH /tmp/out/20260725 - Video.mp4"], exitCode: 0),
    ])
    let download = DownloadService(
        runner: runner,
        ytdlpURL: URL(fileURLWithPath: "/x"),
        ffmpegDirectory: URL(fileURLWithPath: "/y")
    )
    let coordinator = DownloadCoordinator(download: download, retryDelay: .milliseconds(50))
    let template = "%(upload_date)s - %(title)s.%(ext)s"
    let item = DownloadItem(
        url: "u",
        title: "t",
        format: .video(height: 1080),
        fileNameTemplate: template,
        destination: URL(fileURLWithPath: "/tmp")
    )

    let run = Task {
        await coordinator.run(item, tmpDirectory: URL(fileURLWithPath: "/tmp/work"))
    }
    try? await Task.sleep(for: .milliseconds(10))
    item.fileNameTemplate = "%(id)s.%(ext)s"
    await run.value

    #expect(item.state == .done)
    let perCall = runner.recordedArguments.allArguments
    #expect(perCall.count == 3)
    for arguments in perCall {
        guard let outputIndex = arguments.firstIndex(of: "-o") else {
            Issue.record("missing -o")
            continue
        }
        #expect(arguments[outputIndex + 1] == template)
    }
}

@MainActor
@Test func coordinatorDoesNotRetryNon403Errors() async {
    let runner = FakeProcessRunner(
        stderr: "Authorization: Bearer secret\nERROR: Video unavailable at https://cdn.example/x?sig=secret",
        exitCode: 7
    )
    let download = DownloadService(runner: runner, ytdlpURL: URL(fileURLWithPath: "/x"), ffmpegDirectory: URL(fileURLWithPath: "/y"))
    let coordinator = DownloadCoordinator(download: download, retryDelay: .milliseconds(10))
    let item = DownloadItem(
        url: "https://www.youtube.com/watch?v=private",
        title: "t",
        format: .video(height: 1080),
        destination: URL(fileURLWithPath: "/tmp")
    )
    item.includeSubtitles = true
    item.lastEngineChannel = .stable
    item.lastEngineVersion = "2026.07.04"

    await coordinator.run(
        item,
        tmpDirectory: URL(fileURLWithPath: "/tmp/work"),
        detailedDiagnostics: true
    )
    #expect(runner.calls.count == 1)
    if case .failed = item.state {} else { Issue.record("expected .failed, got \(item.state)") }
    let diagnostics = item.failureDiagnostics
    #expect(diagnostics?.host == "youtube.com")
    #expect(diagnostics?.engineChannel == .stable)
    #expect(diagnostics?.engineVersion == "2026.07.04")
    #expect(diagnostics?.outputDescription == "Up to 1080p · MP4")
    #expect(diagnostics?.includeSubtitles == true)
    #expect(diagnostics?.attempts.first?.exitCode == 7)
    #expect(diagnostics?.attempts.first?.detailed == true)
    #expect(diagnostics?.report.contains("Authorization: <redacted>") == true)
    #expect(diagnostics?.report.contains("secret") == false)
    #expect(runner.recordedArguments.arguments.contains("--verbose"))
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

// A transient DNS failure resolving the ephemeral googlevideo CDN host is intermittent, just like
// the 403: a FRESH yt-dlp invocation re-extracts and gets a healthy host, so it retries silently
// (never showing .failed) instead of forcing the user to react. Only a persistent outage fails.
private let dnsResolveError = "ERROR: [download] Got error: HTTPSConnection(host='rr5---sn-hp57ynsl.googlevideo.com', port=443): Failed to resolve 'rr5---sn-hp57ynsl.googlevideo.com' ([Errno 8] nodename nor servname provided, or not known). Giving up after 10 retries"

@MainActor
@Test func coordinatorRetriesOnTransientDNSFailureUpToThreeAttemptsThenFails() async {
    let runner = FakeProcessRunner(stderr: dnsResolveError, exitCode: 1)
    let download = DownloadService(runner: runner, ytdlpURL: URL(fileURLWithPath: "/x"), ffmpegDirectory: URL(fileURLWithPath: "/y"))
    let coordinator = DownloadCoordinator(download: download, retryDelay: .milliseconds(10))
    let item = DownloadItem(url: "u", title: "t", format: .video(height: 1080), destination: URL(fileURLWithPath: "/tmp"))

    await coordinator.run(item, tmpDirectory: URL(fileURLWithPath: "/tmp/work"))
    #expect(runner.calls.count == 3)
    if case .failed = item.state {} else { Issue.record("expected .failed, got \(item.state)") }
}

@MainActor
@Test func coordinatorRecoversSilentlyWhenTransientDNSClearsOnRetry() async {
    let runner = FakeProcessRunner(replays: [
        .init(stderr: dnsResolveError, exitCode: 1),
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
