import Testing
import Foundation
@testable import DownbenderCore

private func probeResult(formats: [DownloadFormat]) -> ProbeResult {
    ProbeResult(videoID: "x", title: "t", thumbnailURL: nil, durationSeconds: nil, availableFormats: formats)
}

@Test func closestMatchPrefersExactThenLowerThenLowest() {
    let probe = probeResult(formats: [.video(height: 1080), .video(height: 720), .video(height: 360), .audioMP3])
    #expect(probe.closestMatch(to: .video(height: 720)) == .video(height: 720))
    #expect(probe.closestMatch(to: .video(height: 480)) == .video(height: 360)) // nearest below
    #expect(probe.closestMatch(to: .video(height: 240)) == .video(height: 360)) // nothing below → lowest listed
    #expect(probe.closestMatch(to: .audioMP3) == .audioMP3)
}

@Test func closestMatchWithoutVideoFallsBackToMP3OrNil() {
    #expect(probeResult(formats: [.audioMP3]).closestMatch(to: .video(height: 1080)) == .audioMP3)
    #expect(probeResult(formats: []).closestMatch(to: .video(height: 1080)) == nil)
}

@MainActor private func makeModel(runner: ProcessRunning, defaults: UserDefaults) -> AppModel {
    let model = AppModel(
        binaries: BundledBinaries(
            ytdlp: URL(fileURLWithPath: "/fake/yt-dlp"),
            ffmpegDirectory: URL(fileURLWithPath: "/ff"),
            deno: nil
        ),
        destination: URL(fileURLWithPath: "/tmp/dest"),
        tmpDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("dq-tmp-\(UUID().uuidString)"),
        appSupportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("dq-\(UUID().uuidString)"),
        cookiesBrowser: nil,
        runner: runner,
        defaults: defaults,
        directSessionFactory: { FailingURLProtocol.session() }
    )
    model.probeRetryDelay = .milliseconds(1)
    return model
}

private func probeFixtureJSON() throws -> String {
    let url = Bundle.module.url(forResource: "probe", withExtension: "json", subdirectory: "Fixtures")!
    return try String(contentsOf: url, encoding: .utf8)
}

@MainActor private func waitWhileProbing(_ item: DownloadItem) async {
    var waited = 0
    while item.state == .probing, waited < 400 {
        waited += 1
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Test func defaultQualityAndOneClickPersist() {
    let suite = "dq-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = makeModel(runner: FakeProcessRunner(), defaults: defaults)
    #expect(first.defaultQuality == nil)
    #expect(first.oneClickDownload == false)
    first.defaultQuality = .video(height: 720)
    first.oneClickDownload = true
    let second = makeModel(runner: FakeProcessRunner(), defaults: defaults)
    #expect(second.defaultQuality == .video(height: 720))
    #expect(second.oneClickDownload == true)
}

@MainActor
@Test func oneClickSkipsThePanelForConfirmedVideos() async throws {
    let suite = "dq-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let runner = FakeProcessRunner(stdoutLines: [try probeFixtureJSON()], exitCode: 0)
    let model = makeModel(runner: runner, defaults: defaults)
    model.defaultQuality = .video(height: 1080)
    model.oneClickDownload = true

    model.addURL("https://youtu.be/abc123")
    let item = model.queue.items[0]
    await waitWhileProbing(item)

    #expect(item.state != .readyToChoose) // panel skipped: straight to the queue pipeline
    #expect(item.format != nil)
}

@MainActor
@Test func withoutOneClickTheVideoStillWaitsForTheChooser() async throws {
    let suite = "dq-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let runner = FakeProcessRunner(stdoutLines: [try probeFixtureJSON()], exitCode: 0)
    let model = makeModel(runner: runner, defaults: defaults)
    model.defaultQuality = .video(height: 1080) // set, but one-click OFF

    model.addURL("https://youtu.be/abc123")
    let item = model.queue.items[0]
    await waitWhileProbing(item)

    #expect(item.state == .readyToChoose)
    #expect(item.format == nil)
}
