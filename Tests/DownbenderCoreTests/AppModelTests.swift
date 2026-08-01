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
        runner: runner,
        directSessionFactory: { FailingURLProtocol.session() }
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
    model.cookiesBrowser = .firefox

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
    model.cookiesBrowser = .brave
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

@MainActor private func waitUntil(_ condition: () -> Bool) async {
    var waited = 0
    while !condition(), waited < 400 {
        waited += 1
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// The probing card is REMOVED on playlist detection (its state stays .probing), so
/// waiting on the card would always exhaust the timeout: wait on the published playlist.
@MainActor private func waitForPendingPlaylist(_ model: AppModel) async {
    await waitUntil { model.pendingPlaylist != nil }
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
@Test func acceptPlaylistEnqueuesOnlySelectedEntriesInSuppliedOrderWithChosenOptions() {
    let model = makeModel(runner: FakeProcessRunner(exitCode: 0))
    model.queue.setMaxConcurrent(0)
    let originalDestination = model.destination
    let selectedDestination = URL(fileURLWithPath: "/tmp/playlist-selection-destination")
    model.destination = selectedDestination
    defer { model.destination = originalDestination }

    let playlist = PlaylistProbe(
        title: "Selection",
        entries: [
            PlaylistEntry(
                url: "https://youtu.be/one",
                title: "One",
                thumbnailURL: URL(string: "https://example.com/one.jpg")
            ),
            PlaylistEntry(url: "https://youtu.be/two", title: "Two"),
            PlaylistEntry(url: "https://youtu.be/three", title: "Three"),
        ]
    )

    model.acceptPlaylist(
        playlist,
        selectedEntries: [playlist.entries[2], playlist.entries[0]],
        format: .video(height: 720),
        includeSubtitles: true
    )

    #expect(model.queue.items.map(\.url) == ["https://youtu.be/three", "https://youtu.be/one"])
    #expect(model.queue.items.map(\.title) == ["Three", "One"])
    #expect(model.queue.items.allSatisfy { $0.state == .queued })
    #expect(model.queue.items.allSatisfy { $0.format == .video(height: 720) })
    #expect(model.queue.items.allSatisfy { $0.includeSubtitles })
    #expect(model.queue.items.allSatisfy { $0.destination == selectedDestination })
    #expect(model.queue.items[1].thumbnailURL == URL(string: "https://example.com/one.jpg"))
}

@MainActor
@Test func acceptingAnEmptyPlaylistSelectionDoesNotEnqueueOrDismissAnalysis() async throws {
    let runner = FakeProcessRunner(stdoutLines: [try playlistFixtureJSON()], exitCode: 0)
    let model = makeModel(runner: runner)
    model.addURL("https://www.youtube.com/playlist?list=PLtest123")
    await waitForPendingPlaylist(model)
    guard let playlist = model.pendingPlaylist else {
        Issue.record("expected pendingPlaylist")
        return
    }

    model.acceptPlaylist(
        playlist,
        selectedEntries: [],
        format: .audioMP3,
        includeSubtitles: true
    )

    #expect(model.queue.items.isEmpty)
    #expect(model.pendingPlaylist == playlist)
}

@MainActor
@Test func playlistSelectionPreservesRepeatedEntriesWithTheSameURL() {
    let model = makeModel(runner: FakeProcessRunner(exitCode: 0))
    model.queue.setMaxConcurrent(0)
    let repeated = PlaylistEntry(url: "https://youtu.be/repeated", title: "Repeated")
    let playlist = PlaylistProbe(title: "Duplicates", entries: [repeated, repeated])

    model.acceptPlaylist(
        playlist,
        selectedEntries: playlist.entries,
        format: .audioMP3
    )

    #expect(model.queue.items.count == 2)
    #expect(model.queue.items.map(\.url) == [repeated.url, repeated.url])
    #expect(model.queue.items.map(\.title) == [repeated.title, repeated.title])
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
@Test func multiplePlaylistScopeChoicesAreHandledInArrivalOrder() {
    let runner = FakeProcessRunner(exitCode: 0)
    let model = makeModel(runner: runner)
    let first = "https://www.youtube.com/watch?v=first&list=RDfirst"
    let second = "https://www.youtube.com/watch?v=second&list=RDsecond"

    model.addURL(first)
    model.addURL(second)

    #expect(model.pendingPlaylistChoice == first)
    model.chooseVideoOnly()
    #expect(model.pendingPlaylistChoice == second)
    #expect(model.queue.items.map(\.url) == [first])

    model.dismissPlaylistChoice()
    #expect(model.pendingPlaylistChoice == nil)
}

@MainActor
@Test func chooseWholePlaylistExpandsThroughTheNormalProbingCard() async throws {
    let runner = FakeProcessRunner(stdoutLines: [try playlistFixtureJSON()], exitCode: 0)
    let model = makeModel(runner: runner)
    model.addURL("https://www.youtube.com/watch?v=vid1&list=PLtest123")

    model.chooseWholePlaylist()

    // Same feedback as any single video: a probing card, no bespoke loading UI.
    #expect(model.queue.items.count == 1)
    #expect(model.queue.items[0].state == .probing)

    await waitForPendingPlaylist(model)
    #expect(model.pendingPlaylist?.entries.count == 3)
    #expect(model.queue.items.isEmpty)
    // The FIRST call is the expansion probe (later calibration probes do carry --no-playlist).
    #expect(runner.recordedArguments.allArguments.first?.contains("--no-playlist") == false)
}

@MainActor
@Test func playlistEstimateIsInstantFromDurationsAndCalibratesFromSample() async throws {
    let runner = FakeProcessRunner(replays: [
        .init(stdoutLines: [try playlistFixtureJSON()], exitCode: 0),
        .init(stdoutLines: [try probeFixtureJSON()], exitCode: 0),
    ])
    let model = makeModel(runner: runner)
    model.addURL("https://www.youtube.com/watch?v=vid1&list=PLtest123")
    model.chooseWholePlaylist()
    await waitForPendingPlaylist(model)
    guard let analysis = model.playlistAnalysis else {
        Issue.record("expected playlistAnalysis")
        return
    }

    // INSTANT estimate, before any calibration: durations 100+200 known, third entry counts
    // as the 150s average → 450s × the nominal 720p rate (200 KB/s).
    if analysis.sampleResults.isEmpty {
        #expect(analysis.estimatedTotalBytes(for: .video(height: 720)) == 90_000_000)
    }

    // Calibration replays the probe fixture for all 3 entries: measured rate replaces nominal.
    await waitUntil { analysis.sampleResults.count == 3 }
    // 3 videos × 30 MB over 3 × 212 s = 141509.43… B/s → × 450 s of playlist.
    let measured = Int64(Double(3 * 30_000_000) / (3 * 212.0) * 450.0)
    #expect(analysis.estimatedTotalBytes(for: .video(height: 720)) == measured)
    // Extracted audio stays on nominal rates because per-video sizes never cover conversions.
    #expect(analysis.estimatedTotalBytes(for: .audioMP3) == 13_500_000)
    #expect(analysis.estimatedTotalBytes(for: .audioM4A) == 10_800_000)
    #expect(analysis.estimatedTotalBytes(for: .audioOpus) == 9_000_000)

    // Accepting attaches what the calibration already learned to each queued item.
    model.acceptPlaylist(analysis.playlist, format: .video(height: 720), includeSubtitles: false)
    #expect(model.playlistAnalysis == nil)
    #expect(model.queue.items.count == 3)
    for item in model.queue.items {
        #expect(item.expectedTotalBytes == 30_000_000)
    }
}

@MainActor
@Test func playlistNominalRatesCoverVideoAndAudioOutputs() {
    #expect(PlaylistAnalysis.nominalRate(for: .video(height: 1440)) == 750_000)
    #expect(PlaylistAnalysis.nominalRate(for: .video(height: 2160)) == 1_500_000)
    #expect(PlaylistAnalysis.nominalRate(for: .maximumVideo) == 1_500_000)
    #expect(PlaylistAnalysis.nominalRate(for: .audioMP3) == 30_000)
    #expect(PlaylistAnalysis.nominalRate(for: .audioM4A) == 24_000)
    #expect(PlaylistAnalysis.nominalRate(for: .audioOpus) == 20_000)

    let analysis = PlaylistAnalysis(
        playlist: PlaylistProbe(
            title: "High resolution",
            entries: [
                PlaylistEntry(url: "https://youtu.be/one", title: "One", durationSeconds: 60),
                PlaylistEntry(url: "https://youtu.be/two", title: "Two", durationSeconds: 120),
            ]
        )
    )

    #expect(analysis.estimatedTotalBytes(for: .video(height: 1440)) == 135_000_000)
    #expect(analysis.estimatedTotalBytes(for: .video(height: 2160)) == 270_000_000)
    #expect(analysis.estimatedTotalBytes(for: .maximumVideo) == 270_000_000)
}

@MainActor
@Test func playlistEstimateUsesOnlySelectedEntriesAndHandlesEmptySelection() {
    let playlist = PlaylistProbe(
        title: "Selected durations",
        entries: [
            PlaylistEntry(url: "https://youtu.be/one", title: "One", durationSeconds: 60),
            PlaylistEntry(url: "https://youtu.be/two", title: "Two", durationSeconds: 120),
            PlaylistEntry(url: "https://youtu.be/three", title: "Three", durationSeconds: 180),
        ]
    )
    let analysis = PlaylistAnalysis(playlist: playlist)

    #expect(
        analysis.estimatedTotalBytes(
            for: .video(height: 720),
            selectedEntries: [playlist.entries[2], playlist.entries[0]]
        ) == 48_000_000
    )
    #expect(
        analysis.estimatedTotalBytes(
            for: .video(height: 720),
            selectedEntries: []
        ) == 0
    )
    // The compatibility API still estimates the complete playlist.
    #expect(analysis.estimatedTotalBytes(for: .video(height: 720)) == 72_000_000)
}

@MainActor
@Test func playlistEstimatePrefersCalibrationFromTheSelectedSubset() {
    let format = DownloadFormat.video(height: 720)
    let playlist = PlaylistProbe(
        title: "Different rates",
        entries: [
            PlaylistEntry(url: "https://youtu.be/slow", title: "Slow", durationSeconds: 100),
            PlaylistEntry(url: "https://youtu.be/fast", title: "Fast", durationSeconds: 200),
        ]
    )
    let analysis = PlaylistAnalysis(playlist: playlist)
    analysis.sampleResults = [
        playlist.entries[0].url: ProbeResult(
            videoID: "slow",
            title: "Slow",
            thumbnailURL: nil,
            durationSeconds: 100,
            availableFormats: [format],
            approxSizeBytes: [format: 10_000_000]
        ),
        playlist.entries[1].url: ProbeResult(
            videoID: "fast",
            title: "Fast",
            thumbnailURL: nil,
            durationSeconds: 200,
            availableFormats: [format],
            approxSizeBytes: [format: 60_000_000]
        ),
    ]

    #expect(
        analysis.estimatedTotalBytes(
            for: format,
            selectedEntries: [playlist.entries[1]]
        ) == 60_000_000
    )
}

@MainActor
@Test func playlistEstimateIgnoresNonpositiveAndNonfiniteDurations() {
    let playlist = PlaylistProbe(
        title: "Malformed durations",
        entries: [
            PlaylistEntry(url: "https://youtu.be/zero", title: "Zero", durationSeconds: 0),
            PlaylistEntry(
                url: "https://youtu.be/infinite",
                title: "Infinite",
                durationSeconds: .infinity
            ),
            PlaylistEntry(url: "https://youtu.be/known", title: "Known", durationSeconds: 90),
        ]
    )
    let analysis = PlaylistAnalysis(playlist: playlist)

    // Neither selected entry has usable metadata, so the valid playlist-wide 90s duration
    // supplies the fallback average for both selected entries.
    #expect(
        analysis.estimatedTotalBytes(
            for: .video(height: 720),
            selectedEntries: [playlist.entries[0], playlist.entries[1]]
        ) == 36_000_000
    )
    // With a valid selected duration, the malformed neighbor is imputed from that selection.
    #expect(
        analysis.estimatedTotalBytes(
            for: .video(height: 720),
            selectedEntries: [playlist.entries[2], playlist.entries[0]]
        ) == 36_000_000
    )
}

@MainActor
@Test func failedPlaylistExpansionLandsOnCardAndRetryRecovers() async throws {
    let runner = FakeProcessRunner(replays: [
        .init(stderr: "ERROR: boom", exitCode: 1),
        .init(stdoutLines: [try playlistFixtureJSON()], exitCode: 0),
    ])
    let model = makeModel(runner: runner)
    model.addURL("https://www.youtube.com/watch?v=vid1&list=PLtest123")
    model.chooseWholePlaylist()

    let item = model.queue.items[0]
    await waitWhileProbing(item)
    guard case .probeFailed = item.state else {
        Issue.record("expected .probeFailed, got \(item.state)")
        return
    }

    // The card remembers it was a playlist expansion: retry expands again, not video-only.
    model.retryProbe(item)
    await waitForPendingPlaylist(model)
    #expect(model.pendingPlaylist?.entries.count == 3)
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
@Test func choosingAudioClearsUnsupportedSubtitleRequest() {
    let model = makeModel(runner: FakeProcessRunner(exitCode: 0))
    model.queue.setMaxConcurrent(0)

    for format in DownloadFormat.audioFormats {
        let item = DownloadItem(
            url: "https://youtu.be/audio-\(format.id)",
            title: format.label,
            destination: URL(fileURLWithPath: "/tmp/dest"),
            state: .readyToChoose
        )
        model.queue.add(item)

        model.choose(format, includeSubtitles: true, for: item)

        #expect(item.format == format)
        #expect(item.includeSubtitles == false)
    }
}

@MainActor
@Test func acceptingAudioPlaylistClearsUnsupportedSubtitleRequest() {
    let model = makeModel(runner: FakeProcessRunner(exitCode: 0))
    model.queue.setMaxConcurrent(0)

    for format in DownloadFormat.audioFormats {
        let playlist = PlaylistProbe(
            title: format.label,
            entries: [
                PlaylistEntry(
                    url: "https://youtu.be/playlist-\(format.id)",
                    title: format.label
                ),
            ]
        )
        model.acceptPlaylist(playlist, format: format, includeSubtitles: true)
    }

    #expect(model.queue.items.map(\.format) == DownloadFormat.audioFormats.map { Optional($0) })
    #expect(model.queue.items.allSatisfy { $0.includeSubtitles == false })
}

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
