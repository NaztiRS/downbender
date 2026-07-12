import Foundation
import Observation

/// One check, one "Update now" for two updatables: the app (GitHub release) and the
/// engine (yt-dlp). An app update supersedes the engine one: the new app ships a fresh
/// bundled engine and the installer drops the Application Support override.
@MainActor @Observable
public final class UnifiedUpdater {
    public enum Phase: Equatable {
        case idle
        case checking
        case upToDate(app: String, engine: String)
        /// At least one side is non-nil.
        case available(appVersion: String?, engineInstalled: String?, engineLatest: String?)
        case workingOnEngine(Double)
        case workingOnApp(Double)
        /// The app was swapped on disk; it takes effect on relaunch.
        case readyToRestart
        case failed(String)
    }

    public private(set) var phase: Phase = .idle

    private let installedAppVersion: String
    private let fetchLatestAppTag: @Sendable () async throws -> String
    private let fetchEngineInstalled: @Sendable () async throws -> String
    private let fetchEngineLatest: @Sendable () async throws -> String
    private let updateEngine: @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void
    private let updateApp: @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void

    public init(
        installedAppVersion: String,
        fetchLatestAppTag: @escaping @Sendable () async throws -> String,
        fetchEngineInstalled: @escaping @Sendable () async throws -> String,
        fetchEngineLatest: @escaping @Sendable () async throws -> String,
        updateEngine: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void,
        updateApp: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void
    ) {
        self.installedAppVersion = installedAppVersion
        self.fetchLatestAppTag = fetchLatestAppTag
        self.fetchEngineInstalled = fetchEngineInstalled
        self.fetchEngineLatest = fetchEngineLatest
        self.updateEngine = updateEngine
        self.updateApp = updateApp
    }

    /// Queries both sides in parallel; one side failing (no release yet, endpoint down)
    /// doesn't kill the check — the working side still reports. Only a total failure becomes .failed.
    public func check() async {
        phase = .checking
        async let appTagResult = Result { try await fetchLatestAppTag() }
        async let engineInstalledResult = Result { try await fetchEngineInstalled() }
        async let engineLatestResult = Result { try await fetchEngineLatest() }
        let (appTag, engineInstalled, engineLatest) = await (appTagResult, engineInstalledResult, engineLatestResult)

        let newAppVersion: String? = (try? appTag.get()).flatMap { tag in
            AppUpdateChecker.isNewer(latestTag: tag, than: installedAppVersion)
                ? tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                : nil
        }
        let engine: (installed: String, latest: String)? = {
            guard let installed = try? engineInstalled.get(), let latest = try? engineLatest.get() else { return nil }
            return (installed, latest)
        }()

        if case .failure(let error) = appTag, engine == nil {
            phase = .failed(error.localizedDescription)
            return
        }

        let engineNeedsUpdate = engine.map { !UpdaterService.isUpToDate(installed: $0.installed, latest: $0.latest) } ?? false
        if newAppVersion == nil && !engineNeedsUpdate {
            phase = .upToDate(app: installedAppVersion, engine: engine?.installed ?? "?")
        } else {
            phase = .available(
                appVersion: newAppVersion,
                engineInstalled: engineNeedsUpdate ? engine?.installed : nil,
                engineLatest: engineNeedsUpdate ? engine?.latest : nil
            )
        }
    }

    public func update() async {
        guard case let .available(appVersion, _, engineLatest) = phase else { return }
        do {
            if let _ = appVersion {
                phase = .workingOnApp(0)
                try await updateApp { [weak self] fraction in
                    Task { @MainActor in
                        if case .workingOnApp = self?.phase { self?.phase = .workingOnApp(fraction) }
                    }
                }
                phase = .readyToRestart
            } else if let engineLatest {
                phase = .workingOnEngine(0)
                try await updateEngine { [weak self] fraction in
                    Task { @MainActor in
                        if case .workingOnEngine = self?.phase { self?.phase = .workingOnEngine(fraction) }
                    }
                }
                phase = .upToDate(app: installedAppVersion, engine: engineLatest)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// async-let needs an expression; Result's throwing initializer wraps one.
private extension Result where Failure == Error {
    init(catching body: @Sendable () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
