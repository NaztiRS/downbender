import Testing
import Foundation
@testable import DownbenderCore

@MainActor
private func makeUpdater(
    installedApp: String = "1.0.0",
    latestAppTag: @escaping @Sendable () async throws -> String = { "v1.0.0" },
    updateApp: @escaping @Sendable (@escaping @Sendable (Double?) -> Void) async throws -> Void = { _ in }
) -> UnifiedUpdater {
    UnifiedUpdater(
        installedAppVersion: installedApp,
        fetchLatestAppTag: latestAppTag,
        updateApp: updateApp
    )
}

struct FakeUpdateError: Error {}

@MainActor @Test func checkReportsUpToDateWhenNothingIsNewer() async {
    let updater = makeUpdater()
    await updater.check()
    #expect(updater.phase == .upToDate(app: "1.0.0"))
}

@MainActor @Test func checkReportsAppUpdate() async {
    let updater = makeUpdater(latestAppTag: { "v1.1.0" })
    await updater.check()
    #expect(updater.phase == .available(appVersion: "1.1.0"))
}

@MainActor @Test func checkFailureSurfacesAsFailed() async {
    let updater = makeUpdater(latestAppTag: { throw FakeUpdateError() })
    await updater.check()
    if case .failed = updater.phase {} else { Issue.record("expected .failed, got \(updater.phase)") }
}

@MainActor @Test func olderReleaseReportsInstalledAppAsUpToDate() async {
    let updater = makeUpdater(installedApp: "2.0.0", latestAppTag: { "v1.9.0" })
    await updater.check()
    #expect(updater.phase == .upToDate(app: "2.0.0"))
}

@MainActor @Test func updateWithAppAvailableInstallsAppAndEndsReadyToRestart() async {
    let appUpdated = SendableBox(false)
    let updater = makeUpdater(
        latestAppTag: { "v1.1.0" },
        updateApp: { onProgress in onProgress(1.0); appUpdated.value = true }
    )
    await updater.check()
    await updater.update()
    #expect(appUpdated.value)
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
    let updater = makeUpdater(
        latestAppTag: { "v1.1.0" },
        updateApp: { onProgress in
            onProgress(1)
            _ = appUpdates.next()
        }
    )

    await updater.checkAndInstallAppUpdate()

    let appUpdateCount = appUpdates.count
    #expect(appUpdateCount == 1)
    #expect(updater.phase == .readyToRestart)
}

@MainActor @Test func automaticUpdateDoesNothingWhenAppIsCurrent() async {
    let appUpdates = CallCounter()
    let updater = makeUpdater(
        updateApp: { _ in _ = appUpdates.next() }
    )

    await updater.checkAndInstallAppUpdate()

    let appUpdateCount = appUpdates.count
    #expect(appUpdateCount == 0)
    #expect(updater.phase == .upToDate(app: "1.0.0"))
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

@MainActor @Test func automaticRequestDuringManualUpdateDoesNotInstallTwice() async {
    let installStarted = AsyncGate()
    let allowInstallToFinish = AsyncGate()
    let fetches = CallCounter()
    let appUpdates = CallCounter()
    let updater = makeUpdater(
        latestAppTag: {
            _ = fetches.next()
            return "v1.1.0"
        },
        updateApp: { _ in
            _ = appUpdates.next()
            await installStarted.open()
            await allowInstallToFinish.wait()
        }
    )
    await updater.check()

    let manualUpdate = Task { @MainActor in
        await updater.update()
    }
    await installStarted.wait()
    await updater.checkAndInstallAppUpdate()
    await allowInstallToFinish.open()
    await manualUpdate.value

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
