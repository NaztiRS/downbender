import Foundation
import Testing
@testable import DownbenderCore

private struct EngineFixtureError: Error {}

private actor EngineGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
private func makeEngineController(
    defaults: UserDefaults,
    nightlyAvailable: SendableBox<Bool>,
    readVersion: @escaping @Sendable (URL) async throws -> String = { url in
        url.lastPathComponent.contains("nightly") ? "2026.08.01.010203" : "2026.07.04"
    },
    install: @escaping @Sendable (
        @escaping @Sendable (Double?) -> Void
    ) async throws -> YtdlpEngineInstallation = { _ in throw EngineFixtureError() }
) -> YtdlpEngineController {
    let stable = URL(fileURLWithPath: "/app/yt-dlp_macos")
    let nightly = URL(fileURLWithPath: "/support/yt-dlp-nightly_macos")
    return YtdlpEngineController(
        stableURL: stable,
        nightlyURL: nightly,
        defaults: defaults,
        fileExists: { url in url == stable || (url == nightly && nightlyAvailable.value) },
        isExecutable: { url in url == stable || (url == nightly && nightlyAvailable.value) },
        readVersion: readVersion,
        installLatestNightly: install
    )
}

@MainActor
@Test func engineDefaultsToBundledStableEvenWhenNightlyExists() {
    let suite = "engine-default-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let controller = makeEngineController(
        defaults: defaults,
        nightlyAvailable: SendableBox(true)
    )

    #expect(controller.selectedChannel == .stable)
    #expect(controller.nightlyInstalled)
}

@MainActor
@Test func validNightlyChoicePersistsAcrossRelaunchAndCanReturnToStable() async throws {
    let suite = "engine-persist-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let available = SendableBox(true)

    let first = makeEngineController(defaults: defaults, nightlyAvailable: available)
    try await first.select(.nightly)
    #expect(first.selectedChannel == .nightly)
    #expect(defaults.string(forKey: YtdlpEngineController.selectedChannelKey) == "nightly")

    let relaunched = makeEngineController(defaults: defaults, nightlyAvailable: available)
    #expect(relaunched.selectedChannel == .nightly)
    let resolved = await relaunched.resolveSelectedEngine()
    #expect(resolved.channel == .nightly)
    #expect(resolved.executableURL.lastPathComponent == "yt-dlp-nightly_macos")

    relaunched.useStable()
    #expect(relaunched.selectedChannel == .stable)
    #expect(relaunched.nightlyInstalled)
    #expect(defaults.string(forKey: YtdlpEngineController.selectedChannelKey) == "stable")
}

@MainActor
@Test func latestSelectionWinsWhileNightlyValidationIsSuspended() async throws {
    let suite = "engine-selection-race-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let validationStarted = EngineGate()
    let finishValidation = EngineGate()
    let controller = makeEngineController(
        defaults: defaults,
        nightlyAvailable: SendableBox(true),
        readVersion: { url in
            if url.lastPathComponent.contains("nightly") {
                await validationStarted.open()
                await finishValidation.wait()
            }
            return "2026.08.01.010203"
        }
    )

    let selectNightly = Task { try await controller.select(.nightly) }
    await validationStarted.wait()
    controller.useStable()
    await finishValidation.open()
    try await selectNightly.value

    #expect(controller.selectedChannel == .stable)
    #expect(defaults.string(forKey: YtdlpEngineController.selectedChannelKey) == "stable")
}

@MainActor
@Test(arguments: ["unknown", "nightly"])
func invalidOrMissingNightlyPreferenceFallsBackAndRepairsDefaults(stored: String) {
    let suite = "engine-repair-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(stored, forKey: YtdlpEngineController.selectedChannelKey)

    let controller = makeEngineController(
        defaults: defaults,
        nightlyAvailable: SendableBox(false)
    )

    #expect(controller.selectedChannel == .stable)
    #expect(defaults.string(forKey: YtdlpEngineController.selectedChannelKey) == "stable")
}

@MainActor
@Test func brokenPersistedNightlyValidatesThenFallsBackToStable() async {
    let suite = "engine-invalid-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("nightly", forKey: YtdlpEngineController.selectedChannelKey)
    let controller = makeEngineController(
        defaults: defaults,
        nightlyAvailable: SendableBox(true),
        readVersion: { _ in throw EngineFixtureError() }
    )

    let resolved = await controller.resolveSelectedEngine()

    #expect(resolved.channel == .stable)
    #expect(controller.selectedChannel == .stable)
    #expect(defaults.string(forKey: YtdlpEngineController.selectedChannelKey) == "stable")
    if case .failed(let message) = controller.phase {
        #expect(message.contains("Stable is active"))
    } else {
        Issue.record("expected a visible validation failure")
    }
}

@MainActor
@Test func cancelledNightlyValidationDoesNotChangeThePersistedSelection() async {
    let suite = "engine-cancelled-validation-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("nightly", forKey: YtdlpEngineController.selectedChannelKey)
    let controller = makeEngineController(
        defaults: defaults,
        nightlyAvailable: SendableBox(true),
        readVersion: { url in
            if url.lastPathComponent.contains("nightly") { throw CancellationError() }
            return "2026.07.04"
        }
    )

    await controller.refreshVersions()
    let resolved = await controller.resolveSelectedEngine()

    #expect(resolved.channel == .stable)
    #expect(controller.selectedChannel == .nightly)
    #expect(defaults.string(forKey: YtdlpEngineController.selectedChannelKey) == "nightly")
    #expect(controller.phase == .idle)
}

@MainActor
@Test func successfulNightlyInstallValidatesBeforeSelectionAndPublishesProgress() async throws {
    let suite = "engine-install-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let available = SendableBox(false)
    let nightly = URL(fileURLWithPath: "/support/yt-dlp-nightly_macos")
    let controller = makeEngineController(
        defaults: defaults,
        nightlyAvailable: available,
        install: { onProgress in
            onProgress(0.6)
            available.value = true
            return YtdlpEngineInstallation(
                executableURL: nightly,
                version: "2026.08.01.010203"
            )
        }
    )

    try await controller.installLatestAndSelect()

    #expect(controller.selectedChannel == .nightly)
    #expect(controller.nightlyInstalled)
    #expect(controller.nightlyVersion == "2026.08.01.010203")
    #expect(controller.phase == .idle)
    #expect((await controller.resolveSelectedEngine()).channel == .nightly)
}

@MainActor
@Test func changingToStableDuringInstallKeepsTheMutexAndUserSelection() async throws {
    let suite = "engine-install-selection-race-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let started = EngineGate()
    let finish = EngineGate()
    let nightly = URL(fileURLWithPath: "/support/yt-dlp-nightly_macos")
    let controller = makeEngineController(
        defaults: defaults,
        nightlyAvailable: SendableBox(true),
        install: { _ in
            await started.open()
            await finish.wait()
            return YtdlpEngineInstallation(
                executableURL: nightly,
                version: "2026.08.01.111213"
            )
        }
    )

    let firstInstall = Task { try await controller.installLatestAndSelect() }
    await started.wait()
    #expect(controller.isInstalling)
    controller.useStable()
    #expect(controller.isInstalling)
    if case .installing = controller.phase {} else {
        Issue.record("changing selection must not release the install lock")
    }
    await #expect(throws: YtdlpEngineSelectionError.installationInProgress) {
        try await controller.installLatestAndSelect()
    }

    await finish.open()
    try await firstInstall.value

    #expect(!controller.isInstalling)
    #expect(controller.selectedChannel == .stable)
    #expect(controller.nightlyVersion == "2026.08.01.111213")
    #expect(controller.phase == .idle)
}

@MainActor
@Test func cancelledInstallRestoresStateWithoutShowingAFailure() async {
    let suite = "engine-cancelled-install-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = makeEngineController(
        defaults: defaults,
        nightlyAvailable: SendableBox(false),
        install: { _ in throw CancellationError() }
    )

    await #expect(throws: CancellationError.self) {
        try await controller.installLatestAndSelect()
    }

    #expect(!controller.isInstalling)
    #expect(controller.selectedChannel == .stable)
    #expect(controller.phase == .idle)
}

@MainActor
@Test(arguments: [YtdlpEngineChannel.stable, .nightly])
func failedNightlyInstallPreservesPreviousUsableSelection(
    previous: YtdlpEngineChannel
) async throws {
    let suite = "engine-rollback-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let available = SendableBox(previous == .nightly)
    let controller = makeEngineController(
        defaults: defaults,
        nightlyAvailable: available
    )
    if previous == .nightly {
        try await controller.select(.nightly)
    }

    await #expect(throws: YtdlpEngineSelectionError.self) {
        try await controller.installLatestAndSelect()
    }

    #expect(controller.selectedChannel == previous)
    #expect(defaults.string(forKey: YtdlpEngineController.selectedChannelKey) == previous.rawValue)
    #expect((await controller.resolveSelectedEngine()).channel == previous)
}
