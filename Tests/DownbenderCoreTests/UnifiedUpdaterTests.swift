import Testing
import Foundation
@testable import DownbenderCore

@MainActor
private func makeUpdater(
    installedApp: String = "1.0.0",
    latestAppTag: @escaping @Sendable () async throws -> String = { "v1.0.0" },
    engineInstalled: @escaping @Sendable () async throws -> String = { "2026.07.04" },
    engineLatest: @escaping @Sendable () async throws -> String = { "2026.07.04" },
    updateEngine: @escaping @Sendable (@escaping @Sendable (Double?) -> Void) async throws -> Void = { _ in },
    updateApp: @escaping @Sendable (@escaping @Sendable (Double?) -> Void) async throws -> Void = { _ in }
) -> UnifiedUpdater {
    UnifiedUpdater(
        installedAppVersion: installedApp,
        fetchLatestAppTag: latestAppTag,
        fetchEngineInstalled: engineInstalled,
        fetchEngineLatest: engineLatest,
        updateEngine: updateEngine,
        updateApp: updateApp
    )
}

struct FakeUpdateError: Error {}

@MainActor @Test func checkReportsUpToDateWhenNothingIsNewer() async {
    let updater = makeUpdater()
    await updater.check()
    #expect(updater.phase == .upToDate(app: "1.0.0", engine: "2026.07.04"))
}

@MainActor @Test func checkReportsAppUpdate() async {
    let updater = makeUpdater(latestAppTag: { "v1.1.0" })
    await updater.check()
    #expect(updater.phase == .available(appVersion: "1.1.0", engineInstalled: nil, engineLatest: nil))
}

@MainActor @Test func checkReportsEngineUpdate() async {
    let updater = makeUpdater(engineLatest: { "2026.08.01" })
    await updater.check()
    #expect(updater.phase == .available(appVersion: nil, engineInstalled: "2026.07.04", engineLatest: "2026.08.01"))
}

@MainActor @Test func checkReportsBothUpdatesAtOnce() async {
    let updater = makeUpdater(latestAppTag: { "v2.0.0" }, engineLatest: { "2026.08.01" })
    await updater.check()
    #expect(updater.phase == .available(appVersion: "2.0.0", engineInstalled: "2026.07.04", engineLatest: "2026.08.01"))
}

/// Before the first public release (404) or offline on one side: the working side still reports.
@MainActor @Test func checkSurvivesAppSideFailure() async {
    let updater = makeUpdater(latestAppTag: { throw FakeUpdateError() }, engineLatest: { "2026.08.01" })
    await updater.check()
    #expect(updater.phase == .available(appVersion: nil, engineInstalled: "2026.07.04", engineLatest: "2026.08.01"))
}

@MainActor @Test func checkFailsWhenBothSidesFail() async {
    let updater = makeUpdater(
        latestAppTag: { throw FakeUpdateError() },
        engineInstalled: { throw FakeUpdateError() },
        engineLatest: { throw FakeUpdateError() }
    )
    await updater.check()
    if case .failed = updater.phase {} else { Issue.record("expected .failed, got \(updater.phase)") }
}

@MainActor @Test func updateEngineOnlyEndsUpToDate() async {
    let engineUpdated = SendableBox(false)
    let updater = makeUpdater(
        engineLatest: { "2026.08.01" },
        updateEngine: { onProgress in onProgress(0.5); engineUpdated.value = true }
    )
    await updater.check()
    await updater.update()
    #expect(engineUpdated.value)
    #expect(updater.phase == .upToDate(app: "1.0.0", engine: "2026.08.01"))
}

/// An app update supersedes the engine one: the new app ships a fresh engine and install() drops the override.
@MainActor @Test func updateWithAppAvailableInstallsAppAndEndsReadyToRestart() async {
    let appUpdated = SendableBox(false)
    let engineUpdated = SendableBox(false)
    let updater = makeUpdater(
        latestAppTag: { "v1.1.0" },
        engineLatest: { "2026.08.01" },
        updateEngine: { _ in engineUpdated.value = true },
        updateApp: { onProgress in onProgress(1.0); appUpdated.value = true }
    )
    await updater.check()
    await updater.update()
    #expect(appUpdated.value)
    #expect(!engineUpdated.value)
    #expect(updater.phase == .readyToRestart)
}

@MainActor @Test func updateFailureSurfacesAsFailed() async {
    let updater = makeUpdater(
        latestAppTag: { "v1.1.0" },
        updateApp: { _ in throw FakeUpdateError() }
    )
    await updater.check()
    await updater.update()
    if case .failed = updater.phase {} else { Issue.record("expected .failed, got \(updater.phase)") }
}

@MainActor @Test func updateWithoutAvailablePhaseIsANoOp() async {
    let updater = makeUpdater()
    await updater.update()
    #expect(updater.phase == .idle)
}

@MainActor @Test func automaticUpdateInstallsOnlyTheAppAndEndsReadyToRestart() async {
    let appUpdates = CallCounter()
    let engineUpdates = CallCounter()
    let updater = makeUpdater(
        latestAppTag: { "v1.1.0" },
        engineLatest: { "2026.08.01" },
        updateEngine: { _ in _ = engineUpdates.next() },
        updateApp: { onProgress in
            onProgress(1)
            _ = appUpdates.next()
        }
    )

    await updater.checkAndInstallAppUpdate()

    let appUpdateCount = appUpdates.count
    let engineUpdateCount = engineUpdates.count
    #expect(appUpdateCount == 1)
    #expect(engineUpdateCount == 0)
    #expect(updater.phase == .readyToRestart)
}

@MainActor @Test func automaticUpdateLeavesAnEngineOnlyUpdateForManualInstallation() async {
    let appUpdates = CallCounter()
    let engineUpdates = CallCounter()
    let updater = makeUpdater(
        engineLatest: { "2026.08.01" },
        updateEngine: { _ in _ = engineUpdates.next() },
        updateApp: { _ in _ = appUpdates.next() }
    )

    await updater.checkAndInstallAppUpdate()

    let appUpdateCount = appUpdates.count
    let engineUpdateCount = engineUpdates.count
    #expect(appUpdateCount == 0)
    #expect(engineUpdateCount == 0)
    #expect(updater.phase == .available(
        appVersion: nil,
        engineInstalled: "2026.07.04",
        engineLatest: "2026.08.01"
    ))
}

@MainActor @Test func concurrentAutomaticRequestsCoalesceIntoOneCheckAndInstall() async {
    let fetchStarted = AsyncGate()
    let allowFetchToFinish = AsyncGate()
    let fetches = CallCounter()
    let appUpdates = CallCounter()
    let updater = makeUpdater(
        latestAppTag: {
            _ = fetches.next()
            await fetchStarted.open()
            await allowFetchToFinish.wait()
            return "v1.1.0"
        },
        updateApp: { _ in _ = appUpdates.next() }
    )

    let firstRequest = Task { @MainActor in
        await updater.checkAndInstallAppUpdate()
    }
    await fetchStarted.wait()
    await updater.checkAndInstallAppUpdate()
    await allowFetchToFinish.open()
    await firstRequest.value

    let fetchCount = fetches.count
    let appUpdateCount = appUpdates.count
    #expect(fetchCount == 1)
    #expect(appUpdateCount == 1)
    #expect(updater.phase == .readyToRestart)
}

@MainActor @Test func automaticRequestDuringManualCheckReusesItsResult() async {
    let fetchStarted = AsyncGate()
    let allowFetchToFinish = AsyncGate()
    let fetches = CallCounter()
    let appUpdates = CallCounter()
    let updater = makeUpdater(
        latestAppTag: {
            _ = fetches.next()
            await fetchStarted.open()
            await allowFetchToFinish.wait()
            return "v1.1.0"
        },
        updateApp: { _ in _ = appUpdates.next() }
    )

    let manualCheck = Task { @MainActor in
        await updater.check()
    }
    await fetchStarted.wait()
    await updater.checkAndInstallAppUpdate()
    await allowFetchToFinish.open()
    await manualCheck.value

    let fetchCount = fetches.count
    let appUpdateCount = appUpdates.count
    #expect(fetchCount == 1)
    #expect(appUpdateCount == 1)
    #expect(updater.phase == .readyToRestart)
}

@MainActor @Test func checksCannotOverwriteWorkingOrReadyToRestartPhases() async {
    let installStarted = AsyncGate()
    let allowInstallToFinish = AsyncGate()
    let fetches = CallCounter()
    let updater = makeUpdater(
        latestAppTag: {
            _ = fetches.next()
            return "v1.1.0"
        },
        updateApp: { onProgress in
            onProgress(0.25)
            await installStarted.open()
            await allowInstallToFinish.wait()
        }
    )
    await updater.check()

    let install = Task { @MainActor in
        await updater.update()
    }
    await installStarted.wait()
    await updater.check()
    if case .workingOnApp = updater.phase {
        // Expected: the concurrent check was ignored.
    } else {
        Issue.record("expected .workingOnApp")
    }

    await allowInstallToFinish.open()
    await install.value
    await updater.check()

    let fetchCount = fetches.count
    #expect(fetchCount == 1)
    #expect(updater.phase == .readyToRestart)
}

/// Thread-safe mutable box for observing side effects from @Sendable closures.
final class SendableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiting = waiters
        waiters.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}
