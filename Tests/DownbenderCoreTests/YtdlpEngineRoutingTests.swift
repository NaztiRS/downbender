import Foundation
import Testing
@testable import DownbenderCore

private struct RoutingEngineError: Error {}

private actor RoutingGate {
    private var openState = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !openState else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !openState else { return }
        openState = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
private func makeRoutingModel(
    runner: ProcessRunning,
    controller: YtdlpEngineController
) -> AppModel {
    AppModel(
        binaries: BundledBinaries(
            ytdlp: controller.stableURL,
            ffmpegDirectory: URL(fileURLWithPath: "/ff"),
            deno: nil
        ),
        destination: URL(fileURLWithPath: "/tmp/engine-routing-dest"),
        tmpDirectory: URL(fileURLWithPath: "/tmp/engine-routing-work"),
        appSupportDirectory: URL(fileURLWithPath: "/tmp/engine-routing-support"),
        runner: runner,
        defaults: UserDefaults(suiteName: "engine-routing-model-\(UUID().uuidString)")!,
        updater: UnifiedUpdater(
            installedAppVersion: "1.0.0",
            fetchLatestAppTag: { "v1.0.0" },
            updateApp: { _ in }
        ),
        engineController: controller,
        directSessionFactory: { FailingURLProtocol.session() }
    )
}

@MainActor
private func waitForEngineItem(
    _ item: DownloadItem,
    until condition: (DownloadItem.State) -> Bool
) async {
    var attempts = 0
    while !condition(item.state), attempts < 500 {
        attempts += 1
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private func engineProbeFixtureJSON() throws -> String {
    let url = Bundle.module.url(
        forResource: "probe",
        withExtension: "json",
        subdirectory: "Fixtures"
    )!
    return try String(contentsOf: url, encoding: .utf8)
}

@MainActor
@Test func selectedNightlyRoutesTheNextProbeAndLabelsTheItem() async throws {
    let suite = "engine-routing-probe-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let stable = URL(fileURLWithPath: "/engines/stable/yt-dlp_macos")
    let nightly = URL(fileURLWithPath: "/engines/nightly/yt-dlp_macos")
    let controller = YtdlpEngineController(
        stableURL: stable,
        nightlyURL: nightly,
        defaults: defaults,
        fileExists: { _ in true },
        isExecutable: { _ in true },
        readVersion: { _ in "2026.08.01.010203" },
        installLatestNightly: { _ in throw RoutingEngineError() }
    )
    try await controller.select(.nightly)
    let runner = FakeProcessRunner(stdoutLines: [try engineProbeFixtureJSON()])
    let model = makeRoutingModel(runner: runner, controller: controller)

    model.addURL("https://youtu.be/nightly-probe")
    let item = try #require(model.queue.items.first)
    await waitForEngineItem(item) { $0 == .readyToChoose }

    #expect(item.state == .readyToChoose)
    #expect(item.lastEngineChannel == .nightly)
    #expect(runner.recordedArguments.allExecutableURLs.first == nightly)
}

@MainActor
@Test func downloadSnapshotsNightlyEvenIfSettingsReturnsToStableMidAttempt() async throws {
    let suite = "engine-routing-snapshot-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let stable = URL(fileURLWithPath: "/engines/stable/yt-dlp_macos")
    let nightly = URL(fileURLWithPath: "/engines/nightly/yt-dlp_macos")
    let controller = YtdlpEngineController(
        stableURL: stable,
        nightlyURL: nightly,
        defaults: defaults,
        fileExists: { _ in true },
        isExecutable: { _ in true },
        readVersion: { _ in "2026.08.01.010203" },
        installLatestNightly: { _ in throw RoutingEngineError() }
    )
    try await controller.select(.nightly)
    let started = RoutingGate()
    let finish = RoutingGate()
    let runner = FakeProcessRunner(
        stdoutLines: ["DBPATH /tmp/engine-routing-dest/video.mp4"],
        beforeReturn: { call in
            guard call == 0 else { return }
            await started.open()
            await finish.wait()
        }
    )
    let model = makeRoutingModel(runner: runner, controller: controller)
    let item = DownloadItem(
        url: "https://youtu.be/snapshot",
        title: "Snapshot",
        format: .video(height: 720),
        destination: model.destination,
        state: .readyToChoose
    )
    model.queue.add(item)

    model.choose(.video(height: 720), for: item)
    await started.wait()
    controller.useStable()
    await finish.open()
    await waitForEngineItem(item) { $0 == .done }

    #expect(item.state == .done)
    #expect(item.lastEngineChannel == .nightly)
    #expect(runner.recordedArguments.allExecutableURLs.first == nightly)
    #expect(controller.selectedChannel == .stable)
}

@MainActor
@Test func tryLatestFixesInstallsThenRetriesSameDownloadWithNightly() async throws {
    let suite = "engine-routing-retry-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let stable = URL(fileURLWithPath: "/engines/stable/yt-dlp_macos")
    let nightly = URL(fileURLWithPath: "/engines/nightly/yt-dlp_macos")
    let available = SendableBox(false)
    let controller = YtdlpEngineController(
        stableURL: stable,
        nightlyURL: nightly,
        defaults: defaults,
        fileExists: { url in url == stable || (url == nightly && available.value) },
        isExecutable: { url in url == stable || (url == nightly && available.value) },
        readVersion: { _ in "2026.08.01.010203" },
        installLatestNightly: { _ in
            available.value = true
            return YtdlpEngineInstallation(
                executableURL: nightly,
                version: "2026.08.01.010203"
            )
        }
    )
    let runner = FakeProcessRunner(replays: [
        .init(stderr: "ERROR: [youtube] Unable to extract player response", exitCode: 1),
        .init(stdoutLines: ["DBPATH /tmp/engine-routing-dest/retried.mp4"], exitCode: 0),
    ])
    let model = makeRoutingModel(runner: runner, controller: controller)
    let destination = model.destination
    let format = DownloadFormat.video(height: 720)
    let item = DownloadItem(
        url: "https://youtu.be/retry-nightly",
        title: "Retry nightly",
        format: format,
        destination: destination,
        state: .readyToChoose
    )
    let originalID = item.id
    model.queue.add(item)

    model.choose(format, for: item)
    await waitForEngineItem(item) {
        if case .failed = $0 { return true }
        return false
    }
    #expect(item.lastEngineChannel == .stable)
    #expect(model.canTryLatestFixes(for: item))

    try await model.retryWithLatestFixes(item)
    await waitForEngineItem(item) { $0 == .done }

    #expect(item.id == originalID)
    #expect(item.state == .done)
    #expect(item.format == format)
    #expect(item.destination == destination)
    #expect(item.lastEngineChannel == .nightly)
    #expect(controller.selectedChannel == .nightly)
    let engineCalls = runner.recordedArguments.allExecutableURLs.filter {
        $0 == stable || $0 == nightly
    }
    #expect(engineCalls.prefix(2).elementsEqual([stable, nightly]))
}

@MainActor
@Test func latestFixesRetryKeepsNightlyWhileWaitingAfterGlobalReturnsToStable() async throws {
    let suite = "engine-routing-pinned-retry-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let stable = URL(fileURLWithPath: "/engines/stable/yt-dlp_macos")
    let nightly = URL(fileURLWithPath: "/engines/nightly/yt-dlp_macos")
    let available = SendableBox(false)
    let controller = YtdlpEngineController(
        stableURL: stable,
        nightlyURL: nightly,
        defaults: defaults,
        fileExists: { url in url == stable || (url == nightly && available.value) },
        isExecutable: { url in url == stable || (url == nightly && available.value) },
        readVersion: { _ in "2026.08.01.010203" },
        installLatestNightly: { _ in
            available.value = true
            return YtdlpEngineInstallation(
                executableURL: nightly,
                version: "2026.08.01.010203"
            )
        }
    )
    let blockerStarted = RoutingGate()
    let finishBlocker = RoutingGate()
    let runner = FakeProcessRunner(
        replays: [
            .init(stderr: "ERROR: [youtube] Unable to extract player response", exitCode: 1),
            .init(stdoutLines: ["DBPATH /tmp/engine-routing-dest/blocker.mp3"]),
            .init(stdoutLines: ["DBPATH /tmp/engine-routing-dest/retried.mp3"]),
        ],
        beforeReturn: { call in
            guard call == 1 else { return }
            await blockerStarted.open()
            await finishBlocker.wait()
        }
    )
    let model = makeRoutingModel(runner: runner, controller: controller)
    model.maxConcurrent = 1
    model.queue.setMaxConcurrent(1)
    let target = DownloadItem(
        url: "https://youtu.be/pinned-nightly",
        title: "Pinned nightly",
        format: .audioMP3,
        destination: model.destination,
        state: .readyToChoose
    )
    model.queue.add(target)
    model.choose(.audioMP3, for: target)
    await waitForEngineItem(target) {
        if case .failed = $0 { return true }
        return false
    }

    let blocker = DownloadItem(
        url: "https://youtu.be/blocker",
        title: "Blocker",
        format: .audioMP3,
        destination: model.destination,
        state: .readyToChoose
    )
    model.queue.add(blocker)
    model.choose(.audioMP3, for: blocker)
    await blockerStarted.wait()

    try await model.retryWithLatestFixes(target)
    #expect(target.state == .queued)
    controller.useStable()
    await finishBlocker.open()
    await waitForEngineItem(target) { $0 == .done }

    #expect(target.lastEngineChannel == .nightly)
    #expect(controller.selectedChannel == .stable)
    let engineCalls = runner.recordedArguments.allExecutableURLs.filter {
        $0 == stable || $0 == nightly
    }
    #expect(engineCalls.elementsEqual([stable, stable, nightly]))
}

@MainActor
@Test func failedLatestFixInstallLeavesItemAndStableSelectionUntouched() async {
    let suite = "engine-routing-failed-install-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let stable = URL(fileURLWithPath: "/engines/stable/yt-dlp_macos")
    let nightly = URL(fileURLWithPath: "/engines/nightly/yt-dlp_macos")
    let controller = YtdlpEngineController(
        stableURL: stable,
        nightlyURL: nightly,
        defaults: defaults,
        fileExists: { $0 == stable },
        isExecutable: { $0 == stable },
        readVersion: { _ in "2026.07.04" },
        installLatestNightly: { _ in throw RoutingEngineError() }
    )
    let model = makeRoutingModel(runner: FakeProcessRunner(), controller: controller)
    let item = DownloadItem(
        url: "https://youtu.be/install-fails",
        title: "Install fails",
        format: .video(height: 720),
        destination: model.destination,
        state: .failed("ERROR: extractor is out of date")
    )
    item.lastEngineChannel = .stable
    model.queue.add(item)

    await #expect(throws: YtdlpEngineSelectionError.self) {
        try await model.retryWithLatestFixes(item)
    }

    #expect(item.state == .failed("ERROR: extractor is out of date"))
    #expect(item.lastEngineChannel == .stable)
    #expect(controller.selectedChannel == .stable)
}

@MainActor
@Test func retryAllFailedWithStableRetriesOnlyFailedMediaItems() async throws {
    let suite = "engine-routing-retry-all-stable-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let stable = URL(fileURLWithPath: "/engines/stable/yt-dlp_macos")
    let nightly = URL(fileURLWithPath: "/engines/nightly/yt-dlp_macos")
    let controller = YtdlpEngineController(
        stableURL: stable,
        nightlyURL: nightly,
        defaults: defaults,
        fileExists: { _ in true },
        isExecutable: { _ in true },
        readVersion: { _ in "2026.08.01.010203" },
        installLatestNightly: { _ in throw RoutingEngineError() }
    )
    try await controller.select(.nightly)
    let model = makeRoutingModel(runner: FakeProcessRunner(), controller: controller)
    model.queue.setMaxConcurrent(0)

    let mediaFailure = DownloadItem(
        url: "https://youtu.be/media-failure",
        title: "Media failure",
        format: .audioMP3,
        destination: model.destination,
        state: .failed("media failed")
    )
    let directFailure = DownloadItem(
        url: "https://example.com/file.zip",
        title: "Direct failure",
        destination: model.destination,
        state: .failed("direct failed")
    )
    directFailure.source = .directFile(DirectFileInfo(suggestedName: "file.zip"))
    let secondMediaFailure = DownloadItem(
        url: "https://youtu.be/second-media-failure",
        title: "Second media failure",
        format: .audioMP3,
        destination: model.destination,
        state: .failed("second media failed")
    )
    let complete = DownloadItem(
        url: "https://youtu.be/complete",
        title: "Complete",
        destination: model.destination,
        state: .done
    )
    for item in [mediaFailure, directFailure, secondMediaFailure, complete] { model.queue.add(item) }

    #expect(model.retryableFailedCount == 2)
    let retried = try await model.retryAllFailed(using: .stable)

    #expect(retried == 2)
    #expect(mediaFailure.state == .queued)
    #expect(mediaFailure.nextEngineChannel == .stable)
    #expect(secondMediaFailure.state == .queued)
    #expect(secondMediaFailure.nextEngineChannel == .stable)
    #expect(directFailure.state == .failed("direct failed"))
    #expect(complete.state == .done)
    #expect(controller.selectedChannel == .stable)
}

@MainActor
@Test func probeFailureOnlyQueueExposesBatchRecoveryActions() {
    let suite = "engine-routing-probe-failure-actions-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let stable = URL(fileURLWithPath: "/engines/stable/yt-dlp_macos")
    let nightly = URL(fileURLWithPath: "/engines/nightly/yt-dlp_macos")
    let controller = YtdlpEngineController(
        stableURL: stable,
        nightlyURL: nightly,
        defaults: defaults,
        fileExists: { $0 == stable },
        isExecutable: { $0 == stable },
        readVersion: { _ in "2026.07.04" },
        installLatestNightly: { _ in throw RoutingEngineError() }
    )
    let model = makeRoutingModel(runner: FakeProcessRunner(), controller: controller)
    model.queue.add(DownloadItem(
        url: "https://youtu.be/probe-failure",
        title: "Probe failure",
        destination: model.destination,
        state: .probeFailed("probe failed")
    ))

    #expect(model.retryableFailedCount == 1)
    #expect(model.hasVisibleQueueActions)
}

@MainActor
@Test func retryAllFailedWithNightlyInstallsBeforeMutatingFailures() async throws {
    let suite = "engine-routing-retry-all-nightly-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let stable = URL(fileURLWithPath: "/engines/stable/yt-dlp_macos")
    let nightly = URL(fileURLWithPath: "/engines/nightly/yt-dlp_macos")
    let available = SendableBox(false)
    let installCount = SendableBox(0)
    let controller = YtdlpEngineController(
        stableURL: stable,
        nightlyURL: nightly,
        defaults: defaults,
        fileExists: { url in url == stable || (url == nightly && available.value) },
        isExecutable: { url in url == stable || (url == nightly && available.value) },
        readVersion: { _ in "2026.08.01.010203" },
        installLatestNightly: { _ in
            installCount.value += 1
            available.value = true
            return YtdlpEngineInstallation(
                executableURL: nightly,
                version: "2026.08.01.010203"
            )
        }
    )
    let model = makeRoutingModel(runner: FakeProcessRunner(), controller: controller)
    model.queue.setMaxConcurrent(0)
    let first = DownloadItem(
        url: "https://youtu.be/first-failure",
        title: "First failure",
        format: .audioMP3,
        destination: model.destination,
        state: .failed("first failed")
    )
    let second = DownloadItem(
        url: "https://youtu.be/second-failure",
        title: "Second failure",
        format: .audioMP3,
        destination: model.destination,
        state: .failed("second failed")
    )
    model.queue.add(first)
    model.queue.add(second)

    let retried = try await model.retryAllFailed(using: .nightly)

    #expect(retried == 2)
    #expect(installCount.value == 1)
    #expect(first.state == .queued)
    #expect(second.state == .queued)
    #expect(first.nextEngineChannel == .nightly)
    #expect(second.nextEngineChannel == .nightly)
    #expect(controller.selectedChannel == .nightly)
}

@MainActor
@Test func failedBulkNightlyInstallLeavesEveryFailureUntouched() async {
    let suite = "engine-routing-retry-all-nightly-failure-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let stable = URL(fileURLWithPath: "/engines/stable/yt-dlp_macos")
    let nightly = URL(fileURLWithPath: "/engines/nightly/yt-dlp_macos")
    let controller = YtdlpEngineController(
        stableURL: stable,
        nightlyURL: nightly,
        defaults: defaults,
        fileExists: { $0 == stable },
        isExecutable: { $0 == stable },
        readVersion: { _ in "2026.07.04" },
        installLatestNightly: { _ in throw RoutingEngineError() }
    )
    let model = makeRoutingModel(runner: FakeProcessRunner(), controller: controller)
    let first = DownloadItem(
        url: "https://youtu.be/first-failure",
        title: "First failure",
        format: .audioMP3,
        destination: model.destination,
        state: .failed("first failed")
    )
    let second = DownloadItem(
        url: "https://youtu.be/second-failure",
        title: "Second failure",
        format: .audioMP3,
        destination: model.destination,
        state: .failed("second failed")
    )
    model.queue.add(first)
    model.queue.add(second)

    await #expect(throws: YtdlpEngineSelectionError.self) {
        try await model.retryAllFailed(using: .nightly)
    }

    #expect(first.state == .failed("first failed"))
    #expect(second.state == .failed("second failed"))
    #expect(controller.selectedChannel == .stable)
}
