import Testing
import Foundation
@testable import DownbenderCore

/// Runner that never returns until cancelled — simulates yt-dlp wedged on a dead read.
private struct WedgedRunner: ProcessRunning {
    func run(
        executableURL: URL,
        arguments: [String],
        onStdoutLine: @Sendable @escaping (String) -> Void
    ) async throws -> ProcessResult {
        try await Task.sleep(for: .seconds(300))
        return ProcessResult(exitCode: 0, stderr: "")
    }
}

@Test func probeThrowsTimedOutWhenRunnerWedges() async {
    let service = ProbeService(runner: WedgedRunner(), ytdlpURL: URL(fileURLWithPath: "/fake/yt-dlp"))
    let start = ContinuousClock.now
    do {
        _ = try await service.probe(url: "https://example.com/v", timeout: .milliseconds(80))
        Issue.record("expected ProbeError.timedOut")
    } catch let error as ProbeError {
        #expect(error == .timedOut)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    #expect(ContinuousClock.now - start < .seconds(3))
}

@Test func probeTimeoutIsTransient() {
    #expect(TransientFailure.isTransient(ProbeError.timedOut))
}
