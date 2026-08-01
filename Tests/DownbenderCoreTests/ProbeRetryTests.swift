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
    #expect(item.failureDiagnostics == nil)
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
    #expect(item.failureDiagnostics?.operation == .analysis)
    #expect(item.failureDiagnostics?.attempts.count == 3)
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
    #expect(item.failureDiagnostics?.attempts.count == 1)
}

@MainActor
@Test func retryProbeWithDiagnosticsPinsEngineLoadsVersionAndUsesVerboseOnce() async {
    let runner = FakeProcessRunner(replays: [
        .init(stderr: "ERROR: Initial failure", exitCode: 1),
        .init(stdoutLines: ["2026.07.04"], exitCode: 0),
        .init(
            stderr: "Cookie: SID=secret\nERROR: Detailed failure at https://cdn.example/x?sig=secret",
            exitCode: 7
        ),
    ])
    let model = makeModel(runner: runner)
    model.addURL("https://youtu.be/abc123")
    let item = model.queue.items[0]
    await waitWhileProbing(item)
    guard case .probeFailed = item.state else {
        Issue.record("expected initial .probeFailed, got \(item.state)")
        return
    }

    model.retryWithDiagnostics(item)
    await waitWhileProbing(item)

    guard case .probeFailed = item.state else {
        Issue.record("expected detailed .probeFailed, got \(item.state)")
        return
    }
    #expect(runner.calls.count == 3)
    let calls = runner.recordedArguments.allArguments
    #expect(!calls[0].contains("--verbose"))
    #expect(calls[1] == ["--ignore-config", "--version"])
    #expect(calls[2].filter { $0 == "--verbose" }.count == 1)
    #expect(item.lastEngineChannel == .stable)
    #expect(item.lastEngineVersion == "2026.07.04")
    #expect(item.failureDiagnostics?.engineVersion == "2026.07.04")
    #expect(item.failureDiagnostics?.attempts.count == 1)
    #expect(item.failureDiagnostics?.attempts.first?.exitCode == 7)
    #expect(item.failureDiagnostics?.attempts.first?.detailed == true)
    #expect(item.failureDiagnostics?.report.contains("secret") == false)
}
