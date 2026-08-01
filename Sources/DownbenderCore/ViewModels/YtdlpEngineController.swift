import Foundation
import Observation

/// Owns the user's yt-dlp channel choice and the separately cached nightly binary.
/// The bundled stable executable is immutable and is always the final fallback.
@MainActor @Observable
public final class YtdlpEngineController {
    public enum Phase: Equatable, Sendable {
        case idle
        /// nil means the server did not expose a total download size.
        case installing(Double?)
        case failed(String)
    }

    public static let selectedChannelKey = "ytdlpEngineChannel"

    public let stableURL: URL
    public let nightlyURL: URL
    public private(set) var selectedChannel: YtdlpEngineChannel
    public private(set) var stableVersion: String?
    public private(set) var nightlyVersion: String?
    public private(set) var nightlyInstalled: Bool
    public private(set) var phase: Phase = .idle
    public private(set) var isInstalling = false

    private let defaults: UserDefaults
    private let fileExists: (URL) -> Bool
    private let isExecutable: (URL) -> Bool
    private let readVersion: @Sendable (URL) async throws -> String
    private let installLatestNightly: @Sendable (
        @escaping @Sendable (Double?) -> Void
    ) async throws -> YtdlpEngineInstallation
    @ObservationIgnored private var validatedNightlyThisLaunch = false
    @ObservationIgnored private var selectionRevision: UInt = 0

    public init(
        stableURL: URL,
        nightlyURL: URL,
        defaults: UserDefaults = .standard,
        fileExists: @escaping (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.path)
        },
        isExecutable: @escaping (URL) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0.path)
        },
        readVersion: @escaping @Sendable (URL) async throws -> String,
        installLatestNightly: @escaping @Sendable (
            @escaping @Sendable (Double?) -> Void
        ) async throws -> YtdlpEngineInstallation
    ) {
        self.stableURL = stableURL
        self.nightlyURL = nightlyURL
        self.defaults = defaults
        self.fileExists = fileExists
        self.isExecutable = isExecutable
        self.readVersion = readVersion
        self.installLatestNightly = installLatestNightly

        let nightlyInstalled = fileExists(nightlyURL) && isExecutable(nightlyURL)
        self.nightlyInstalled = nightlyInstalled
        let stored = defaults.string(forKey: Self.selectedChannelKey)
            .flatMap(YtdlpEngineChannel.init(rawValue:))
        if stored == .nightly, nightlyInstalled {
            self.selectedChannel = .nightly
        } else {
            self.selectedChannel = .stable
            if stored != nil || defaults.string(forKey: Self.selectedChannelKey) != nil {
                defaults.set(YtdlpEngineChannel.stable.rawValue, forKey: Self.selectedChannelKey)
            }
        }
    }

    /// Re-reads versions for Settings and validates a persisted nightly choice before it is used.
    public func refreshVersions() async {
        do {
            stableVersion = try await readVersion(stableURL)
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            stableVersion = nil
        }
        guard !Task.isCancelled, !isInstalling else { return }
        nightlyInstalled = fileExists(nightlyURL) && isExecutable(nightlyURL)
        guard nightlyInstalled else {
            nightlyVersion = nil
            validatedNightlyThisLaunch = false
            if selectedChannel == .nightly {
                fallBackToStable(
                    message: "The installed nightly engine is missing or isn't executable. Stable is active."
                )
            }
            return
        }

        do {
            nightlyVersion = try await validateNightly()
            if case .failed = phase { phase = .idle }
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            fallBackToStable(
                message: "Nightly couldn't launch or report its version. Stable is active. \(error.localizedDescription)"
            )
        }
    }

    /// Returns one immutable engine snapshot for the complete operation. A broken persisted
    /// nightly selection is repaired and the operation continues with bundled stable.
    public func resolveSelectedEngine() async -> YtdlpEngineDescriptor {
        await resolveEngine(selectedChannel)
    }

    /// Resolves an explicit per-attempt channel without changing a valid global selection.
    /// A requested nightly that no longer validates still repairs the global state to stable.
    public func resolveEngine(_ channel: YtdlpEngineChannel) async -> YtdlpEngineDescriptor {
        guard channel == .nightly else {
            return stableDescriptor
        }
        do {
            let version = try await validateNightly()
            return YtdlpEngineDescriptor(
                channel: .nightly,
                executableURL: nightlyURL,
                version: version
            )
        } catch {
            if error is CancellationError || Task.isCancelled { return stableDescriptor }
            fallBackToStable(
                message: "Nightly couldn't launch or report its version. Stable is active. \(error.localizedDescription)"
            )
            return stableDescriptor
        }
    }

    /// Detailed diagnostics ask the actual engine to identify itself once. Ordinary downloads
    /// avoid this subprocess; cached versions from Settings are reused whenever available.
    public func diagnosticVersion(for channel: YtdlpEngineChannel) async -> String? {
        switch channel {
        case .stable:
            if let stableVersion { return stableVersion }
            guard let version = try? await readVersion(stableURL)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !version.isEmpty
            else { return nil }
            stableVersion = version
            return version
        case .nightly:
            if let nightlyVersion { return nightlyVersion }
            return try? await validateNightly()
        }
    }

    public func select(_ channel: YtdlpEngineChannel) async throws {
        guard !isInstalling else { throw YtdlpEngineSelectionError.installationInProgress }
        switch channel {
        case .stable:
            useStable()
        case .nightly:
            guard nightlyInstalled else { throw YtdlpEngineSelectionError.nightlyNotInstalled }
            let startingRevision = selectionRevision
            do {
                nightlyVersion = try await validateNightly()
                guard selectionRevision == startingRevision else { return }
                selectedChannel = .nightly
                defaults.set(channel.rawValue, forKey: Self.selectedChannelKey)
                selectionRevision &+= 1
                phase = .idle
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                guard selectionRevision == startingRevision else { return }
                fallBackToStable(
                    message: "Nightly couldn't launch or report its version. Stable is active. \(error.localizedDescription)"
                )
                throw YtdlpEngineSelectionError.validationFailed(error.localizedDescription)
            }
        }
    }

    public func useStable() {
        selectedChannel = .stable
        defaults.set(YtdlpEngineChannel.stable.rawValue, forKey: Self.selectedChannelKey)
        selectionRevision &+= 1
        if !isInstalling { phase = .idle }
    }

    /// Downloads and validates the current official nightly before selecting it. The installer
    /// does not touch the previous nightly until checksum, permissions and `--version` pass.
    public func installLatestAndSelect() async throws {
        guard !isInstalling else { throw YtdlpEngineSelectionError.installationInProgress }
        let previousChannel = selectedChannel
        let previousVersion = nightlyVersion
        let previousPhase = phase
        let startingRevision = selectionRevision
        isInstalling = true
        phase = .installing(0)
        defer { isInstalling = false }

        do {
            let installation = try await installLatestNightly { [weak self] fraction in
                Task { @MainActor in self?.advanceInstallProgress(fraction) }
            }
            guard installation.executableURL.standardizedFileURL == nightlyURL.standardizedFileURL else {
                throw YtdlpEngineSelectionError.unexpectedInstallLocation
            }
            nightlyInstalled = true
            nightlyVersion = installation.version
            validatedNightlyThisLaunch = true
            if selectionRevision == startingRevision {
                selectedChannel = .nightly
                defaults.set(YtdlpEngineChannel.nightly.rawValue, forKey: Self.selectedChannelKey)
                selectionRevision &+= 1
            }
            phase = .idle
        } catch {
            nightlyVersion = previousVersion
            nightlyInstalled = fileExists(nightlyURL) && isExecutable(nightlyURL)
            if selectionRevision == startingRevision {
                selectedChannel = previousChannel
                defaults.set(previousChannel.rawValue, forKey: Self.selectedChannelKey)
            }
            if error is CancellationError || Task.isCancelled {
                phase = previousPhase
                throw CancellationError()
            }
            let wrapped = YtdlpEngineSelectionError.installationFailed(
                error.localizedDescription,
                fallback: selectedChannel
            )
            phase = .failed(wrapped.localizedDescription)
            throw wrapped
        }
    }

    private var stableDescriptor: YtdlpEngineDescriptor {
        YtdlpEngineDescriptor(
            channel: .stable,
            executableURL: stableURL,
            version: stableVersion
        )
    }

    private func validateNightly() async throws -> String {
        try Task.checkCancellation()
        guard nightlyInstalled, fileExists(nightlyURL), isExecutable(nightlyURL) else {
            throw YtdlpEngineSelectionError.nightlyNotInstalled
        }
        if validatedNightlyThisLaunch, let nightlyVersion { return nightlyVersion }
        let version = try await readVersion(nightlyURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        guard !version.isEmpty else {
            throw YtdlpEngineSelectionError.validationFailed("The version output was empty.")
        }
        validatedNightlyThisLaunch = true
        nightlyVersion = version
        return version
    }

    private func fallBackToStable(message: String) {
        selectedChannel = .stable
        defaults.set(YtdlpEngineChannel.stable.rawValue, forKey: Self.selectedChannelKey)
        selectionRevision &+= 1
        validatedNightlyThisLaunch = false
        if !isInstalling { phase = .failed(message) }
    }

    private func advanceInstallProgress(_ reported: Double?) {
        guard isInstalling, case .installing(let current) = phase else { return }
        guard let reported else {
            if current == 0 { phase = .installing(nil) }
            return
        }
        let clamped = min(max(reported, 0), 1)
        phase = .installing(max(current ?? 0, clamped))
    }
}
