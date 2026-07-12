import Testing
import Foundation
@testable import DownbenderCore

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
        "[download] Destination: /tmp/work/v.f137.mp4",
        "DBPROG  50.0% NA NA 1.0MiB/s 01:00",
        "[download] Destination: /tmp/work/v.f140.m4a",
        "DBPROG 100.0% NA NA 1.0MiB/s 00:00",
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
    // Video at 50% → 0.425 (85% weight); audio at 100% → 1.0
    #expect(sink.values.count == 2)
    #expect(abs(sink.values[0] - 0.425) < 0.0001)
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

@Test func downloadServiceThrowsOnFailure() async {
    let runner = FakeProcessRunner(stderr: "ERROR", exitCode: 1)
    let service = DownloadService(runner: runner, ytdlpURL: URL(fileURLWithPath: "/x"), ffmpegDirectory: URL(fileURLWithPath: "/y"))
    await #expect(throws: DownloadError.self) {
        try await service.download(url: "u", format: .audioMP3, destination: URL(fileURLWithPath: "/d"), tmpDirectory: URL(fileURLWithPath: "/t"), onProgress: { _ in })
    }
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
