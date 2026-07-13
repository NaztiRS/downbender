import Testing
import Foundation
@testable import DownbenderCore

@MainActor
@Test func clipboardWatcherDetectsNewURLOnce() {
    let w = ClipboardWatcher()
    w.check(pasteboardString: "https://youtu.be/abc123")
    #expect(w.detectedURL == "https://youtu.be/abc123")
    w.detectedURL = nil
    w.check(pasteboardString: "https://youtu.be/abc123")
    #expect(w.detectedURL == nil)
    w.check(pasteboardString: "https://youtu.be/xyz789")
    #expect(w.detectedURL == "https://youtu.be/xyz789")
}

// MARK: - Inline probe (addURL)

@MainActor private func makeModel(runner: ProcessRunning, notifier: CompletionNotifying? = nil) -> AppModel {
    AppModel(
        binaries: BundledBinaries(
            ytdlp: URL(fileURLWithPath: "/fake/yt-dlp"),
            ffmpegDirectory: URL(fileURLWithPath: "/ff"),
            deno: nil
        ),
        destination: URL(fileURLWithPath: "/tmp/dest"),
        tmpDirectory: URL(fileURLWithPath: "/tmp/work"),
        appSupportDirectory: URL(fileURLWithPath: "/tmp/support"),
        cookiesBrowser: nil,
        notifier: notifier,
        runner: runner
    )
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
@Test func addURLShowsCardImmediatelyThenBecomesReadyToChoose() async throws {
    let runner = FakeProcessRunner(stdoutLines: [try probeFixtureJSON()], exitCode: 0)
    let model = makeModel(runner: runner)

    model.addURL("https://youtu.be/abc123")

    #expect(model.queue.items.count == 1)
    let item = model.queue.items[0]
    #expect(item.state == .probing)
    #expect(item.title == "https://youtu.be/abc123")

    await waitWhileProbing(item)
    #expect(item.state == .readyToChoose)
    #expect(item.title == "Test video")
    #expect(item.probe != nil)
    #expect(item.format == nil)   // the user picks the quality later
}

@MainActor
@Test func addURLMarksProbeFailedOnErrorAndRetryProbeRecovers() async throws {
    let runner = FakeProcessRunner(replays: [
        .init(stderr: "ERROR: nope", exitCode: 1),
        .init(stdoutLines: [try probeFixtureJSON()], exitCode: 0),
    ])
    let model = makeModel(runner: runner)

    model.addURL("https://youtu.be/abc123")
    let item = model.queue.items[0]
    await waitWhileProbing(item)
    guard case .probeFailed = item.state else {
        Issue.record("expected .probeFailed, got \(item.state)")
        return
    }

    model.retryProbe(item)
    #expect(item.state == .probing)
    await waitWhileProbing(item)
    #expect(item.state == .readyToChoose)
}

@MainActor
@Test func chooseSetsFormatDestinationAndExpectedBytesThenStarts() async throws {
    let runner = FakeProcessRunner(stdoutLines: [try probeFixtureJSON()], exitCode: 0)
    let model = makeModel(runner: runner)
    model.addURL("https://youtu.be/abc123")
    let item = model.queue.items[0]
    await waitWhileProbing(item)
    guard let probe = item.probe, let format = probe.availableFormats.first else {
        Issue.record("probe returned no formats")
        return
    }

    model.choose(format, for: item)

    #expect(item.format == format)
    #expect(item.expectedTotalBytes == probe.approxSizeBytes[format])
    #expect(item.state != .readyToChoose)   // it started (queued or downloading)
}

@MainActor
@Test func deleteFileRemovesFileAndCard() async throws {
    let runner = FakeProcessRunner(exitCode: 0)
    let model = makeModel(runner: runner)
    let fm = FileManager.default
    let file = fm.temporaryDirectory.appendingPathComponent("downbender-test-\(UUID().uuidString).mp4")
    fm.createFile(atPath: file.path, contents: Data("x".utf8))

    let item = DownloadItem(url: "u", title: "t", format: .video(height: 1080), destination: fm.temporaryDirectory, state: .done)
    item.deliveredFileURL = file
    model.queue.add(item)

    try model.deleteFile(of: item)

    #expect(!fm.fileExists(atPath: file.path))
    #expect(model.queue.items.isEmpty)
}

// MARK: - Reveal in Finder

@MainActor
@Test func revealOutcomeDistinguishesExistingMissingAndUnknownFile() async throws {
    let model = makeModel(runner: FakeProcessRunner(exitCode: 0))
    let fm = FileManager.default
    let file = fm.temporaryDirectory.appendingPathComponent("downbender-test-\(UUID().uuidString).mp4")
    fm.createFile(atPath: file.path, contents: Data("x".utf8))
    defer { try? fm.removeItem(at: file) }

    let item = DownloadItem(url: "u", title: "t", format: .video(height: 1080), destination: fm.temporaryDirectory, state: .done)

    #expect(model.revealOutcome(for: item) == .openFolder(fm.temporaryDirectory))

    item.deliveredFileURL = file
    #expect(model.revealOutcome(for: item) == .reveal(file))

    try fm.removeItem(at: file)
    #expect(model.revealOutcome(for: item) == .missing)
}

@MainActor
@Test func removeCancelsInFlightProbe() async throws {
    let runner = FakeProcessRunner(stdoutLines: [try probeFixtureJSON()], exitCode: 0)
    let model = makeModel(runner: runner)
    model.addURL("https://youtu.be/abc123")
    let item = model.queue.items[0]

    model.remove(item)
    #expect(model.queue.items.isEmpty)

    // the in-flight probe must not resurrect the card or break anything
    try? await Task.sleep(for: .milliseconds(100))
    #expect(model.queue.items.isEmpty)
}

// MARK: - Configurable browser cookies

@MainActor
@Test func probeUsesSelectedCookiesBrowser() async throws {
    let runner = FakeProcessRunner(stdoutLines: [try probeFixtureJSON()], exitCode: 0)
    let model = makeModel(runner: runner)
    model.cookiesBrowser = "firefox"

    model.addURL("https://youtu.be/abc123")
    await waitWhileProbing(model.queue.items[0])

    let args = runner.recordedArguments.arguments
    #expect(args.contains("--cookies-from-browser"))
    #expect(args.contains("firefox"))
}

@MainActor
@Test func probeOmitsCookiesFlagByDefault() async throws {
    let runner = FakeProcessRunner(stdoutLines: [try probeFixtureJSON()], exitCode: 0)
    let model = makeModel(runner: runner)   // makeModel passes cookiesBrowser: nil

    model.addURL("https://youtu.be/abc123")
    await waitWhileProbing(model.queue.items[0])

    #expect(!runner.recordedArguments.arguments.contains("--cookies-from-browser"))
}

@MainActor
@Test func cookiesBrowserPersistsToInjectedDefaults() {
    let suite = "test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(
        binaries: BundledBinaries(
            ytdlp: URL(fileURLWithPath: "/fake/yt-dlp"),
            ffmpegDirectory: URL(fileURLWithPath: "/ff"),
            deno: nil
        ),
        destination: URL(fileURLWithPath: "/tmp/dest"),
        tmpDirectory: URL(fileURLWithPath: "/tmp/work"),
        appSupportDirectory: URL(fileURLWithPath: "/tmp/support"),
        cookiesBrowser: nil,
        runner: FakeProcessRunner(),
        defaults: defaults
    )
    model.cookiesBrowser = "brave"
    #expect(defaults.string(forKey: AppModel.cookiesBrowserKey) == "brave")
    model.cookiesBrowser = nil
    #expect(defaults.string(forKey: AppModel.cookiesBrowserKey) == nil)
}

// MARK: - Completion notifications

@MainActor
final class SpyNotifier: CompletionNotifying {
    var events: [(title: String, success: Bool, filePath: String?)] = []
    func downloadFinished(title: String, success: Bool, filePath: String?) {
        events.append((title, success, filePath))
    }
}

@MainActor private func isFinished(_ state: DownloadItem.State) -> Bool {
    if case .failed = state { return true }
    return state == .done || state == .cancelled
}

@MainActor private func waitUntilFinished(_ item: DownloadItem) async {
    var waited = 0
    while !isFinished(item.state), waited < 400 {
        waited += 1
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Test func notifierFiresOnSuccessfulDownload() async throws {
    let runner = FakeProcessRunner(replays: [
        .init(stdoutLines: [try probeFixtureJSON()], exitCode: 0),        // probe
        .init(stdoutLines: ["DBPATH /tmp/dest/song.mp3"], exitCode: 0),  // download
    ])
    let spy = SpyNotifier()
    let model = makeModel(runner: runner, notifier: spy)

    model.addURL("https://youtu.be/abc123")
    let item = model.queue.items[0]
    await waitWhileProbing(item)
    model.choose(.audioMP3, for: item)
    await waitUntilFinished(item)

    #expect(item.state == .done)
    #expect(spy.events.count == 1)
    #expect(spy.events[0].success == true)
    #expect(spy.events[0].filePath == "/tmp/dest/song.mp3")
}

@MainActor
@Test func notifierFiresOnFailedDownload() async throws {
    let runner = FakeProcessRunner(replays: [
        .init(stdoutLines: [try probeFixtureJSON()], exitCode: 0),
        .init(stderr: "ERROR: boom", exitCode: 1),
    ])
    let spy = SpyNotifier()
    let model = makeModel(runner: runner, notifier: spy)

    model.addURL("https://youtu.be/abc123")
    let item = model.queue.items[0]
    await waitWhileProbing(item)
    model.choose(.audioMP3, for: item)
    await waitUntilFinished(item)

    #expect(spy.events.count == 1)
    #expect(spy.events[0].success == false)
}

// MARK: - Playlists

private func playlistFixtureJSON() throws -> String {
    let url = Bundle.module.url(forResource: "playlist", withExtension: "json", subdirectory: "Fixtures")!
    return try String(contentsOf: url, encoding: .utf8)
}

/// The probing card is REMOVED on playlist detection (its state stays .probing), so
/// waiting on the card would always exhaust the timeout: wait on the published playlist.
@MainActor private func waitForPendingPlaylist(_ model: AppModel) async {
    var waited = 0
    while model.pendingPlaylist == nil, waited < 400 {
        waited += 1
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Test func playlistURLRemovesProbingCardAndPublishesPendingPlaylist() async throws {
    let runner = FakeProcessRunner(stdoutLines: [try playlistFixtureJSON()], exitCode: 0)
    let model = makeModel(runner: runner)

    model.addURL("https://www.youtube.com/playlist?list=PLtest123")
    await waitForPendingPlaylist(model)

    #expect(model.queue.items.isEmpty)
    #expect(model.pendingPlaylist?.title == "Test playlist")
    #expect(model.pendingPlaylist?.entries.count == 3)
}

@MainActor
@Test func acceptPlaylistEnqueuesEveryEntryWithChosenFormat() async throws {
    let runner = FakeProcessRunner(replays: [
        .init(stdoutLines: [try playlistFixtureJSON()], exitCode: 0),
        .init(stdoutLines: ["DBPATH /tmp/dest/out.mp4"], exitCode: 0),
    ])
    let model = makeModel(runner: runner)
    model.addURL("https://www.youtube.com/playlist?list=PLtest123")
    await waitForPendingPlaylist(model)
    guard let playlist = model.pendingPlaylist else {
        Issue.record("expected pendingPlaylist")
        return
    }

    model.acceptPlaylist(playlist, format: .video(height: 720), includeSubtitles: true)

    #expect(model.pendingPlaylist == nil)
    #expect(model.queue.items.count == 3)
    #expect(model.queue.items[0].title == "First video")
    for queued in model.queue.items {
        #expect(queued.format == .video(height: 720))
        #expect(queued.includeSubtitles)
    }
    for queued in model.queue.items {
        await waitUntilFinished(queued)
        #expect(queued.state == .done)
    }
}

@MainActor
@Test func watchURLWithListAsksForScopeInsteadOfProbing() async throws {
    let runner = FakeProcessRunner(stdoutLines: [try probeFixtureJSON()], exitCode: 0)
    let model = makeModel(runner: runner)

    model.addURL("https://www.youtube.com/watch?v=abc123&list=RDabc123")

    #expect(model.queue.items.isEmpty)
    #expect(model.pendingPlaylistChoice == "https://www.youtube.com/watch?v=abc123&list=RDabc123")
    // Nothing probed until the user picks a scope.
    #expect(runner.recordedArguments.allArguments.isEmpty)
}

@MainActor
@Test func chooseVideoOnlyProbesTheSingleVideo() async throws {
    let runner = FakeProcessRunner(stdoutLines: [try probeFixtureJSON()], exitCode: 0)
    let model = makeModel(runner: runner)
    model.addURL("https://www.youtube.com/watch?v=abc123&list=RDabc123")

    model.chooseVideoOnly()

    #expect(model.pendingPlaylistChoice == nil)
    #expect(model.queue.items.count == 1)
    let item = model.queue.items[0]
    await waitWhileProbing(item)
    #expect(item.state == .readyToChoose)
    #expect(runner.recordedArguments.arguments.contains("--no-playlist"))
}

@MainActor
@Test func chooseWholePlaylistExpandsIntoPendingPlaylist() async throws {
    let runner = FakeProcessRunner(stdoutLines: [try playlistFixtureJSON()], exitCode: 0)
    let model = makeModel(runner: runner)
    model.addURL("https://www.youtube.com/watch?v=vid1&list=PLtest123")

    model.chooseWholePlaylist()
    await waitForPendingPlaylist(model)

    #expect(model.pendingPlaylist?.entries.count == 3)
    #expect(model.queue.items.isEmpty)
    #expect(!runner.recordedArguments.arguments.contains("--no-playlist"))
}

@MainActor
@Test func emptyPlaylistMarksCardProbeFailed() async throws {
    let json = """
    {"_type": "playlist", "title": "Empty", "entries": []}
    """
    let runner = FakeProcessRunner(stdoutLines: [json], exitCode: 0)
    let model = makeModel(runner: runner)

    model.addURL("https://www.youtube.com/playlist?list=PLempty")
    let item = model.queue.items[0]
    await waitWhileProbing(item)

    #expect(model.pendingPlaylist == nil)
    guard case .probeFailed(let message) = item.state else {
        Issue.record("expected .probeFailed, got \(item.state)")
        return
    }
    #expect(message == "Playlist is empty.")
}

// MARK: - Subtitles

@MainActor
@Test func chooseWithSubtitlesDownloadsWithEmbedFlags() async throws {
    let runner = FakeProcessRunner(replays: [
        .init(stdoutLines: [try probeFixtureJSON()], exitCode: 0),
        .init(stdoutLines: ["DBPATH /tmp/dest/Test video.mp4"], exitCode: 0),
    ])
    let model = makeModel(runner: runner)
    model.addURL("https://youtu.be/abc123")
    let item = model.queue.items[0]
    await waitWhileProbing(item)

    model.choose(.video(height: 1080), includeSubtitles: true, for: item)
    await waitUntilFinished(item)

    #expect(item.state == .done)
    #expect(item.includeSubtitles)
    // allArguments: the last call is the ffprobe honesty check, not yt-dlp.
    #expect(runner.recordedArguments.allArguments.contains { $0.contains("--embed-subs") })
}
