import Foundation
import Observation

/// Checks and installs Downbender application updates.
@MainActor @Observable
public final class UnifiedUpdater {
    public enum Phase: Equatable {
        case idle
        case checking
        case upToDate(app: String)
        case available(appVersion: String)
        /// nil fraction = indeterminate (the server didn't report a total size).
        case workingOnApp(Double?)
        /// The app was swapped on disk; it takes effect on relaunch.
        case readyToRestart
        case failed(String)
    }

    public private(set) var phase: Phase = .idle

    private enum ActiveOperation {
        case checking
        case manualUpdate
        case automaticAppUpdate
    }

    private let installedAppVersion: String
    private let fetchLatestAppTag: @Sendable () async throws -> String
    private let updateApp: @Sendable (@escaping @Sendable (Double?) -> Void) async throws -> Void
    @ObservationIgnored private var activeOperation: ActiveOperation?
    /// If automatic updating is enabled while a manual check/update is suspended, the
    /// operation already in flight finishes the request instead of racing a second one.
    @ObservationIgnored private var automaticAppUpdateRequested = false

    public init(
        installedAppVersion: String,
        fetchLatestAppTag: @escaping @Sendable () async throws -> String,
        updateApp: @escaping @Sendable (@escaping @Sendable (Double?) -> Void) async throws -> Void
    ) {
        self.installedAppVersion = installedAppVersion
        self.fetchLatestAppTag = fetchLatestAppTag
        self.updateApp = updateApp
    }

    /// Queries the latest application release without starting a duplicate operation.
    public func check() async {
        guard activeOperation == nil, phase != .readyToRestart else { return }
        activeOperation = .checking
        defer { activeOperation = nil }

        await performCheck()
        if automaticAppUpdateRequested {
            automaticAppUpdateRequested = false
            activeOperation = .automaticAppUpdate
            await installAvailableAppOnly()
        }
    }

    /// Checks for updates and silently installs Downbender when a newer release exists.
    /// Concurrent automatic calls coalesce, while a request arriving during a manual
    /// check reuses that check's result.
    public func checkAndInstallAppUpdate() async {
        guard phase != .readyToRestart else { return }
        switch activeOperation {
        case nil:
            activeOperation = .automaticAppUpdate
            defer { activeOperation = nil }
            await performCheck()
            await installAvailableAppOnly()
        case .checking, .manualUpdate:
            automaticAppUpdateRequested = true
        case .automaticAppUpdate:
            return
        }
    }

    private func performCheck() async {
        phase = .checking
        do {
            let latestTag = try await fetchLatestAppTag()
            if AppUpdateChecker.isNewer(latestTag: latestTag, than: installedAppVersion) {
                phase = .available(
                    appVersion: latestTag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                )
            } else {
                phase = .upToDate(app: installedAppVersion)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    public func update() async {
        guard activeOperation == nil, phase != .readyToRestart else { return }
        activeOperation = .manualUpdate
        defer { activeOperation = nil }

        await performManualUpdate()
        if automaticAppUpdateRequested {
            automaticAppUpdateRequested = false
            guard phase != .readyToRestart else { return }
            activeOperation = .automaticAppUpdate
            await performCheck()
            await installAvailableAppOnly()
        }
    }

    private func performManualUpdate() async {
        guard case .available = phase else { return }
        do {
            try await installApp()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func installAvailableAppOnly() async {
        guard case .available = phase else { return }
        do {
            try await installApp()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func installApp() async throws {
        phase = .workingOnApp(0)
        try await updateApp { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .workingOnApp(let current) = self.phase else { return }
                self.phase = .workingOnApp(Self.advancingProgress(current: current, reported: fraction))
            }
        }
        phase = .readyToRestart
    }

    /// Progress callbacks can be noisy, late, or briefly unknown across redirects. Keep the
    /// visible bar clamped and monotonic; only switch to indeterminate before real progress begins.
    nonisolated static func advancingProgress(current: Double?, reported: Double?) -> Double? {
        guard let reported else {
            return current == 0 ? nil : current
        }
        let clamped = min(max(reported, 0), 1)
        guard let current else { return clamped }
        return max(current, clamped)
    }
}
