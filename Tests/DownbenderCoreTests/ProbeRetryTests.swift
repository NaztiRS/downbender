import Testing
import Foundation
@testable import DownbenderCore

@MainActor private func makeModel(runner: ProcessRunning) -> AppModel {
    let model = AppModel(
        binaries: BundledBinaries(
            ytdlp: URL(fileURLWithPath: "/fake/yt-dlp"),
            ffmpegDirectory: URL(fileURLWithPath: "/ff"),
            deno: nil
        ),
        destination: URL(fileURLWithPath: "/tmp/dest"),
        tmpDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("pr-tmp-\(UUID().uuidString)"),
        appSupportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("pr-\(UUID().uuidString)"),
        cookiesBrowser: nil,
        runner: runner,
        directSessionFactory: { FailingURLProtocol.session() }
    )
    model.probeRetryDelay = .milliseconds(1)
    return model
}

@MainActor private func waitWhileProbing(_ item: DownloadItem) async {
    var waited = 0
    while item.state == .probing, waited < 400 {
        waited += 1
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private func probeFixtureJSON() throws -> String {
    let url = Bundle.module.url(forResource: "probe", withExtension: "json", subdirectory: "Fixtures")!
    return try String(contentsOf: url, encoding: .utf8)
}

@MainActor
@Test func transientProbeFailureRetriesSilentlyAndRecovers() async throws {
    let runner = FakeProcessRunner(replays: [
        .init(stderr: "ERROR: Failed to resolve 'rr3---sn-x.googlevideo.com'", exitCode: 1),
        .init(stdoutLines: [try probeFixtureJSON()], exitCode: 0),
    ])
    let model = makeModel(runner: runner)
    model.addURL("https://youtu.be/abc123")
    let item = model.queue.items[0]
    await waitWhileProbing(item)
    #expect(item.state == .readyToChoose)
    #expect(runner.calls.count == 2)
}

@MainActor
@Test func transientProbeFailureGivesUpAfterThreeAttempts() async {
    let runner = FakeProcessRunner(stderr: "ERROR: Failed to resolve 'host'", exitCode: 1)
    let model = makeModel(runner: runner)
    model.addURL("https://youtu.be/abc123")
    let item = model.queue.items[0]
    await waitWhileProbing(item)
    guard case .probeFailed = item.state else {
        Issue.record("expected .probeFailed, got \(item.state)"); return
    }
    #expect(runner.calls.count == 3)
}

@MainActor
@Test func nonTransientProbeFailureDoesNotRetry() async {
    let runner = FakeProcessRunner(stderr: "ERROR: This video is private", exitCode: 1)
    let model = makeModel(runner: runner)
    model.addURL("https://youtu.be/abc123")
    let item = model.queue.items[0]
    await waitWhileProbing(item)
    guard case .probeFailed = item.state else {
        Issue.record("expected .probeFailed, got \(item.state)"); return
    }
    #expect(runner.calls.count == 1)
}
