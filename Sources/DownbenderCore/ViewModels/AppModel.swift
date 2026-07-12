import Foundation
import Observation

@MainActor @Observable
public final class AppModel {
    public var destination: URL
    public var maxConcurrent: Int = 2
    public static let cookiesBrowserKey = "cookiesBrowser"
    /// Browser to borrow cookies from (nil = none); passed per invocation so a Settings change applies to the very next probe/download.
    public var cookiesBrowser: String? {
        didSet {
            if let cookiesBrowser { defaults.set(cookiesBrowser, forKey: Self.cookiesBrowserKey) }
            else { defaults.removeObject(forKey: Self.cookiesBrowserKey) }
        }
    }
    public let clipboard = ClipboardWatcher()
    public let appUpdate = AppUpdateChecker()
    public private(set) var queue: QueueViewModel!

    private let probe: ProbeService
    private let coordinator: DownloadCoordinator
    private let tmpDirectory: URL
    private let appSupportDirectory: URL
    private let ytdlpURL: URL
    private let runner: ProcessRunning
    private let defaults: UserDefaults
    private let notifier: CompletionNotifying?

    public init(
        binaries: BundledBinaries,
        destination: URL,
        tmpDirectory: URL,
        appSupportDirectory: URL,
        cookiesBrowser: String? = nil,
        notifier: CompletionNotifying? = nil,
        runner: ProcessRunning = ProcessRunner(),
        defaults: UserDefaults = .standard
    ) {
        self.destination = destination
        self.tmpDirectory = tmpDirectory
        self.appSupportDirectory = appSupportDirectory
        self.ytdlpURL = binaries.ytdlp
        self.runner = runner
        self.defaults = defaults
        self.notifier = notifier
        self.cookiesBrowser = cookiesBrowser
        self.probe = ProbeService(runner: runner, ytdlpURL: binaries.ytdlp, denoURL: binaries.deno)
        let download = DownloadService(
            runner: runner, ytdlpURL: binaries.ytdlp, ffmpegDirectory: binaries.ffmpegDirectory,
            denoURL: binaries.deno
        )
        let inspector = MediaInspector(
            runner: runner, ffprobeURL: binaries.ffmpegDirectory.appendingPathComponent("ffprobe")
        )
        self.coordinator = DownloadCoordinator(download: download, inspect: inspector.videoDimensions(of:))
        self.queue = QueueViewModel(maxConcurrent: maxConcurrent, perform: { [weak self, coordinator, tmpDirectory] item in
            await coordinator.run(item, tmpDirectory: tmpDirectory, cookiesBrowser: self?.cookiesBrowser)
            switch item.state {
            case .done:
                self?.notifier?.downloadFinished(title: item.title, success: true, filePath: item.deliveredFileURL?.path)
            case .failed:
                self?.notifier?.downloadFinished(title: item.title, success: false, filePath: nil)
            default:
                break   // paused/cancelled are intentional user actions: no notification
            }
        })
    }

    /// In-flight probe tasks, per item: cancelled if the user removes the card.
    private var probeTasks: [UUID: Task<Void, Never>] = [:]

    /// Creates the card immediately ("probing" state) and probes in a background Task, one per URL.
    public func addURL(_ url: String) {
        let item = DownloadItem(url: url, title: url, destination: destination, state: .probing)
        queue.add(item)
        runProbe(for: item)
    }

    public func retryProbe(_ item: DownloadItem) {
        guard case .probeFailed = item.state else { return }
        item.state = .probing
        runProbe(for: item)
    }

    private func runProbe(for item: DownloadItem) {
        probeTasks[item.id] = Task { @MainActor [weak self] in
            defer { self?.probeTasks[item.id] = nil }
            do {
                let result = try await self?.probe.probe(url: item.url, cookiesBrowser: self?.cookiesBrowser)
                guard let result, !Task.isCancelled else { return }
                item.title = result.title
                item.thumbnailURL = result.thumbnailURL
                item.probe = result
                item.state = .readyToChoose
            } catch {
                guard !Task.isCancelled else { return }
                item.state = .probeFailed(error.localizedDescription)
            }
        }
    }

    public func choose(_ format: DownloadFormat, for item: DownloadItem) {
        item.format = format
        item.destination = destination
        item.expectedTotalBytes = item.probe?.approxSizeBytes[format]
        queue.start(item)
    }

    /// Removes the card from the list (cancelling any in-flight probe or download). Does not touch files.
    public func remove(_ item: DownloadItem) {
        probeTasks[item.id]?.cancel()
        probeTasks[item.id] = nil
        queue.remove(item)
    }

    public enum RevealOutcome: Equatable {
        case reveal(URL)
        /// The delivered path was never known: opening the destination folder is the best we can do.
        case openFolder(URL)
        case missing
    }

    /// The existence check lives here (not in the view) so ".missing" warns instead of opening Finder.
    public func revealOutcome(for item: DownloadItem) -> RevealOutcome {
        guard let url = item.deliveredFileURL else { return .openFolder(item.destination) }
        return FileManager.default.fileExists(atPath: url.path) ? .reveal(url) : .missing
    }

    /// Permanently deletes the delivered file and removes the card; confirmation happens in the UI.
    public func deleteFile(of item: DownloadItem) throws {
        if let url = item.deliveredFileURL, FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        remove(item)
    }

    public func makeUnifiedUpdater() -> UnifiedUpdater {
        let engine = UpdaterService(appSupportDirectory: appSupportDirectory)
        let selfUpdater = AppSelfUpdater(
            runner: runner,
            installURL: Bundle.main.bundleURL,
            expectedBundleID: Bundle.main.bundleIdentifier ?? "com.naztirs.downbender",
            appSupportDirectory: appSupportDirectory
        )
        let runner = self.runner
        let ytdlpURL = self.ytdlpURL
        return UnifiedUpdater(
            installedAppVersion: Downbender.version,
            fetchLatestAppTag: { try await UpdaterService.latestVersion(from: AppUpdateChecker.releaseAPIURL) },
            fetchEngineInstalled: { try await engine.installedVersion(runner: runner, ytdlpURL: ytdlpURL) },
            fetchEngineLatest: { try await UpdaterService.latestVersion() },
            updateEngine: { onProgress in _ = try await engine.updateYtdlp(onProgress: onProgress) },
            updateApp: { onProgress in try await selfUpdater.update(onProgress: onProgress) }
        )
    }
}
