import Testing
import Foundation
@testable import DownbenderCore

/// Emits some lines, then goes silent for `hang` before exiting 0.
private struct SilentAfterLinesRunner: ProcessRunning {
    var lines: [String]
    var hang: Duration
    func run(
        executableURL: URL,
        arguments: [String],
        onStdoutLine: @Sendable @escaping (String) -> Void
    ) async throws -> ProcessResult {
        for line in lines { onStdoutLine(line) }
        try await Task.sleep(for: hang)
        return ProcessResult(exitCode: 0, stderr: "")
    }
}

private func makeService(runner: ProcessRunning) -> DownloadService {
    DownloadService(runner: runner, ytdlpURL: URL(fileURLWithPath: "/fake/yt-dlp"),
                    ffmpegDirectory: URL(fileURLWithPath: "/ff"))
}

@Test func downloadThrowsStalledWhenProgressStops() async {
    // The Destination line arms the watchdog (download phase began), then silence.
    let runner = SilentAfterLinesRunner(lines: ["[download] Destination: /tmp/a.f137.mp4"], hang: .seconds(300))
    let service = makeService(runner: runner)
    let start = ContinuousClock.now
    do {
        _ = try await service.download(
            url: "u", format: .video(height: 1080),
            destination: URL(fileURLWithPath: "/tmp/dest"),
            tmpDirectory: URL(fileURLWithPath: "/tmp/work"),
            stallTimeout: .milliseconds(120),
            onProgress: { _ in }
        )
        Issue.record("expected DownloadError.stalled")
    } catch let error as DownloadError {
        #expect(error == .stalled)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    #expect(ContinuousClock.now - start < .seconds(5))
}

@Test func mergePhaseSilenceDoesNotTripTheWatchdog() async throws {
    // After [Merger] the watchdog disarms: local CPU work may be legitimately silent.
    let runner = SilentAfterLinesRunner(
        lines: ["[download] Destination: /tmp/a.f137.mp4", "[Merger] Merging formats into \"/tmp/a.mp4\""],
        hang: .milliseconds(400)
    )
    let service = makeService(runner: runner)
    let delivered = try await service.download(
        url: "u", format: .video(height: 1080),
        destination: URL(fileURLWithPath: "/tmp/dest"),
        tmpDirectory: URL(fileURLWithPath: "/tmp/work"),
        stallTimeout: .milliseconds(120),
        onProgress: { _ in }
    )
    #expect(delivered == nil)   // no DBPATH line — nil is the normal "no path printed" answer
}

@Test func stalledIsTransient() {
    #expect(TransientFailure.isTransient(DownloadError.stalled))
}
