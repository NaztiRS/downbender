import Testing
import Foundation
@testable import DownbenderCore

@Test func downloadServiceIgnoresProvisionalHLSCompletionAndUsesActualSinglePhase() async throws {
    // Real yt-dlp HLS startup: the first 1 KiB probe reports 100% while the
    // manifest still has 135 fragments left. That provisional sample must not
    // become the old hard-coded 85% video weight.
    let runner = FakeProcessRunner(stdoutLines: [
        "DBPLAN|NA|NA|NA|NA|NA|NA|301-4|NA|4082.989",
        "[download] Destination: /tmp/work/video.mp4",
        "DBPROG|downloading|100.0%|1024|1024|0|135|244.93B/s|00:00",
        "DBPROG|downloading|2.2%|3072|138240.0|0|135|244.93B/s|00:00",
        "DBPROG|downloading|0.4%|2012728|543436560.0|1|135|409.65KiB/s|01:44",
        "DBPROG|finished|100.0%|543436560|543436560|135|135|4.00MiB/s|00:00",
    ], exitCode: 0)
    let service = DownloadService(
        runner: runner,
        ytdlpURL: URL(fileURLWithPath: "/fake/yt-dlp"),
        ffmpegDirectory: URL(fileURLWithPath: "/app/ff")
    )
    let sink = FractionSink()

    _ = try await service.download(
        url: "https://youtu.be/abc123",
        format: .video(height: 1080),
        destination: URL(fileURLWithPath: "/tmp/dest"),
        tmpDirectory: URL(fileURLWithPath: "/tmp/work"),
        onProgress: { sink.append($0.fraction) }
    )

    let values = sink.values
    guard values.count == 4 else {
        Issue.record("expected four HLS progress samples, got \(values)")
        return
    }
    #expect(values[0] == 0)
    #expect(values[1] == 0)
    #expect(abs(values[2] - (1.0 / 135.0)) < 0.0001)
    #expect(values[3] == 1)
    #expect(!values.contains { $0 >= 0.84 && $0 < 1 })
}

@Test func downloadServiceUnifiesPhasesIntoOneProgress() async throws {
    // Realistic session: video (phase 1), audio (phase 2), merge. The user sees ONE download.
    let runner = FakeProcessRunner(stdoutLines: [
        "[download] Destination: /tmp/work/v.f137.mp4",
        "DBPROG  50.0% 40000000 80000000 1.0MiB/s 01:00",
        "DBPROG 100.0% 80000000 80000000 2.0MiB/s 00:00",
        "[download] Destination: /tmp/work/v.f140.m4a",
        "DBPROG  50.0% 10000000 20000000 1.0MiB/s 00:10",
        "DBPROG 100.0% 20000000 20000000 1.0MiB/s 00:00",
    ], exitCode: 0)
    let service = DownloadService(
        runner: runner,
        ytdlpURL: URL(fileURLWithPath: "/fake/yt-dlp"),
        ffmpegDirectory: URL(fileURLWithPath: "/app/ff")
    )
    let sink = FractionSink()
    let delivered = try await service.download(
        url: "https://youtu.be/abc123",
        format: .video(height: 1080),
        destination: URL(fileURLWithPath: "/tmp/dest"),
        tmpDirectory: URL(fileURLWithPath: "/tmp/work"),
        expectedTotalBytes: 100_000_000,
        onProgress: { sink.append($0.fraction) }
    )
    let expected: [Double] = [0.4, 0.8, 0.9, 1.0]
    #expect(sink.values.count == expected.count)
    for (got, want) in zip(sink.values, expected) {
        #expect(abs(got - want) < 0.0001)
    }
    #expect(delivered == nil)
}

@Test func downloadServiceWeightsPhasesWhenBytesUnavailable() async throws {
    let runner = FakeProcessRunner(stdoutLines: [
        "DBPLAN|137|NA|2500|140|NA|129|137+140|NA|2629",
        "[download] Destination: /tmp/work/v.f137.mp4",
        "DBPROG|downloading|50.0%|NA|NA|NA|NA|1.0MiB/s|01:00",
        "[download] Destination: /tmp/work/v.f140.m4a",
        "DBPROG|finished|100.0%|NA|NA|NA|NA|1.0MiB/s|00:00",
    ], exitCode: 0)
    let service = DownloadService(
        runner: runner,
        ytdlpURL: URL(fileURLWithPath: "/fake/yt-dlp"),
        ffmpegDirectory: URL(fileURLWithPath: "/app/ff")
    )
    let sink = FractionSink()
    _ = try await service.download(
        url: "https://youtu.be/abc123",
        format: .video(height: 1080),
        destination: URL(fileURLWithPath: "/tmp/dest"),
        tmpDirectory: URL(fileURLWithPath: "/tmp/work"),
        onProgress: { sink.append($0.fraction) }
    )
    // The actual selected bitrates determine the phase weights; there is no 85/15 constant.
    #expect(sink.values.count == 2)
    #expect(abs(sink.values[0] - (2_500.0 / 2_629.0 * 0.5)) < 0.0001)
    #expect(abs(sink.values[1] - 1.0) < 0.0001)
}

@Test func downloadServiceReturnsDeliveredPathFromDBPATHLine() async throws {
    let runner = FakeProcessRunner(stdoutLines: [
        "DBPROG 100.0% 2.0MiB/s 00:00",
        "DBPATH /tmp/out/video.mp4",
    ], exitCode: 0)
    let service = DownloadService(
        runner: runner,
        ytdlpURL: URL(fileURLWithPath: "/fake/yt-dlp"),
        ffmpegDirectory: URL(fileURLWithPath: "/app/ff")
    )
    let delivered = try await service.download(
        url: "https://youtu.be/abc123",
        format: .video(height: 1080),
        destination: URL(fileURLWithPath: "/tmp/dest"),
        tmpDirectory: URL(fileURLWithPath: "/tmp/work"),
        onProgress: { _ in }
    )
    #expect(delivered?.path == "/tmp/out/video.mp4")
}

@Test func allAudioOutputsUseOneProgressPhaseAndReturnTheirFinalExtension() async throws {
    for format in DownloadFormat.audioFormats {
        let path = "/tmp/out/track.\(format.id)"
        let runner = FakeProcessRunner(stdoutLines: [
            "[download] Destination: /tmp/work/source.webm",
            "DBPROG  50.0% NA NA 1.0MiB/s 00:01",
            "DBPATH \(path)",
        ], exitCode: 0)
        let service = DownloadService(
            runner: runner,
            ytdlpURL: URL(fileURLWithPath: "/fake/yt-dlp"),
            ffmpegDirectory: URL(fileURLWithPath: "/app/ff")
        )
        let sink = FractionSink()

        let delivered = try await service.download(
            url: "https://youtu.be/abc123",
            format: format,
            destination: URL(fileURLWithPath: "/tmp/dest"),
            tmpDirectory: URL(fileURLWithPath: "/tmp/work"),
            onProgress: { sink.append($0.fraction) }
        )

        #expect(sink.values == [0.5])
        #expect(delivered?.path == path)
    }
}

@Test func downloadServiceThrowsOnFailure() async {
    let runner = FakeProcessRunner(stderr: "ERROR", exitCode: 1)
    let service = DownloadService(runner: runner, ytdlpURL: URL(fileURLWithPath: "/x"), ffmpegDirectory: URL(fileURLWithPath: "/y"))
    await #expect(throws: DownloadError.self) {
        try await service.download(url: "u", format: .audioMP3, destination: URL(fileURLWithPath: "/d"), tmpDirectory: URL(fileURLWithPath: "/t"), onProgress: { _ in })
    }
}

@Test func downloadServiceFailurePreservesExitAndUsesVerboseOnlyWhenRequested() async {
    let runner = FakeProcessRunner(
        stderr: "Cookie: SID=secret\nERROR: unavailable at https://cdn.example/x?sig=secret",
        exitCode: 9
    )
    let service = DownloadService(
        runner: runner,
        ytdlpURL: URL(fileURLWithPath: "/x"),
        ffmpegDirectory: URL(fileURLWithPath: "/y")
    )

    do {
        try await service.download(
            url: "https://youtu.be/abc123",
            format: .audioOpus,
            destination: URL(fileURLWithPath: "/d"),
            tmpDirectory: URL(fileURLWithPath: "/t"),
            detailedDiagnostics: true,
            onProgress: { _ in }
        )
        Issue.record("expected DownloadError")
    } catch let error as DownloadError {
        guard case .ytdlpFailed(let details) = error else {
            Issue.record("unexpected download error: \(error)")
            return
        }
        #expect(details.exitCode == 9)
        #expect(details.summary == "ERROR: unavailable at <url>")
        #expect(details.output.contains("Cookie: <redacted>"))
        #expect(!details.output.contains("secret"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    #expect(runner.recordedArguments.arguments.filter { $0 == "--verbose" }.count == 1)
}

@Test func downloadServicePassesSubtitleFlagsThrough() async throws {
    let runner = FakeProcessRunner(stdoutLines: ["DBPATH /tmp/out/video.mp4"], exitCode: 0)
    let service = DownloadService(
        runner: runner,
        ytdlpURL: URL(fileURLWithPath: "/fake/yt-dlp"),
        ffmpegDirectory: URL(fileURLWithPath: "/app/ff")
    )
    _ = try await service.download(
        url: "https://youtu.be/abc123",
        format: .video(height: 720),
        destination: URL(fileURLWithPath: "/tmp/dest"),
        tmpDirectory: URL(fileURLWithPath: "/tmp/work"),
        includeSubtitles: true,
        onProgress: { _ in }
    )
    #expect(runner.recordedArguments.arguments.contains("--embed-subs"))
}
