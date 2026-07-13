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

    /// Watch link that also carries a `list=`: parked here until the user picks video vs playlist.
    public var pendingPlaylistChoice: String?

    /// Creates the card immediately ("probing" state) and probes in a background Task, one per URL.
    /// Watch+list URLs stop first at a scope prompt (RootView) instead of probing right away.
    public func addURL(_ url: String) {
        if MediaURL.pointsToVideoInPlaylist(url) {
            pendingPlaylistChoice = url
            return
        }
        addVideoURL(url)
    }

    public func chooseVideoOnly() {
        guard let url = pendingPlaylistChoice else { return }
        pendingPlaylistChoice = nil
        addVideoURL(url)
    }

    /// Opens the playlist panel IMMEDIATELY (loading state) and analyzes in the background:
    /// mix/playlist probes can take long and must never block the UI.
    public func chooseWholePlaylist() {
        guard let url = pendingPlaylistChoice else { return }
        pendingPlaylistChoice = nil
        startPlaylistAnalysis(url: url)
    }

    private func addVideoURL(_ url: String) {
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
                let outcome = try await self?.probe.probe(url: item.url, cookiesBrowser: self?.cookiesBrowser)
                guard let outcome, !Task.isCancelled else { return }
                switch outcome {
                case .video(let result):
                    item.title = result.title
                    item.thumbnailURL = result.thumbnailURL
                    item.probe = result
                    item.state = .readyToChoose
                case .playlist(let playlist):
                    guard !playlist.entries.isEmpty else {
                        item.state = .probeFailed("Playlist is empty.")
                        return
                    }
                    // The probing card becomes the playlist panel: one choice for all entries.
                    self?.queue.remove(item)
                    self?.presentAnalysis(url: item.url, playlist: playlist)
                }
            } catch {
                guard !Task.isCancelled else { return }
                item.state = .probeFailed(error.localizedDescription)
            }
        }
    }

    /// Live playlist analysis behind the panel sheet; non-nil while the sheet is up.
    public private(set) var playlistAnalysis: PlaylistAnalysis?
    private var analysisTask: Task<Void, Never>?

    /// Entry list of the analysis, once known (also what the older tests observe).
    public var pendingPlaylist: PlaylistProbe? { playlistAnalysis?.playlist }

    private func startPlaylistAnalysis(url: String) {
        analysisTask?.cancel()
        let analysis = PlaylistAnalysis(url: url)
        playlistAnalysis = analysis
        analysisTask = Task { @MainActor [weak self] in
            await self?.expandAndEstimate(analysis)
        }
    }

    /// Pure playlist URLs arrive here with the entries already probed by the card's flat probe.
    private func presentAnalysis(url: String, playlist: PlaylistProbe) {
        analysisTask?.cancel()
        let analysis = PlaylistAnalysis(url: url)
        analysis.playlist = playlist
        playlistAnalysis = analysis
        analysisTask = Task { @MainActor [weak self] in
            await self?.estimateSizes(analysis)
        }
    }

    public func retryPlaylistAnalysis() {
        guard let stale = playlistAnalysis, stale.failure != nil else { return }
        startPlaylistAnalysis(url: stale.url)
    }

    /// Closing the sheet (cancel or accept) stops any in-flight estimation probes.
    public func dismissPlaylistAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        playlistAnalysis = nil
    }

    private func expandAndEstimate(_ analysis: PlaylistAnalysis) async {
        do {
            let outcome = try await probe.probe(url: analysis.url, cookiesBrowser: cookiesBrowser, expandPlaylist: true)
            guard !Task.isCancelled, playlistAnalysis === analysis else { return }
            switch outcome {
            case .playlist(let playlist) where !playlist.entries.isEmpty:
                analysis.playlist = playlist
            case .playlist:
                analysis.failure = "Playlist is empty."
                return
            case .video:
                // The "playlist" resolved to a single video after all: back to the normal card flow.
                dismissPlaylistAnalysis()
                addVideoURL(analysis.url)
                return
            }
        } catch {
            guard !Task.isCancelled else { return }
            analysis.failure = error.localizedDescription
            return
        }
        await estimateSizes(analysis)
    }

    /// Full-probes every entry through a small sliding window (all at once would spawn one
    /// yt-dlp process per video) purely to refine the panel's size estimate.
    private func estimateSizes(_ analysis: PlaylistAnalysis) async {
        guard let entries = analysis.playlist?.entries, !entries.isEmpty else { return }
        let probe = self.probe
        let cookies = cookiesBrowser
        await withTaskGroup(of: (String, ProbeResult?).self) { group in
            let window = 3
            var nextIndex = 0
            while nextIndex < min(window, entries.count) {
                let url = entries[nextIndex].url
                nextIndex += 1
                group.addTask { (url, (try? await probe.probe(url: url, cookiesBrowser: cookies))?.videoResult) }
            }
            for await (url, result) in group {
                guard !Task.isCancelled, playlistAnalysis === analysis else { break }
                analysis.analyzedCount += 1
                if let result { analysis.results[url] = result }
                if nextIndex < entries.count {
                    let next = entries[nextIndex].url
                    nextIndex += 1
                    group.addTask { (next, (try? await probe.probe(url: next, cookiesBrowser: cookies))?.videoResult) }
                }
            }
            group.cancelAll()
        }
    }

    /// Enqueues every entry directly (no blocking per-item probe; whatever the background
    /// estimation already learned travels with the item as its expected size).
    public func acceptPlaylist(_ playlist: PlaylistProbe, format: DownloadFormat, includeSubtitles: Bool = false) {
        for entry in playlist.entries {
            let item = DownloadItem(
                url: entry.url,
                title: entry.title,
                thumbnailURL: entry.thumbnailURL,
                format: format,
                destination: destination,
                state: .queued
            )
            item.includeSubtitles = includeSubtitles
            if let known = playlistAnalysis?.results[entry.url] {
                item.probe = known
                item.expectedTotalBytes = known.approxDownloadSize(for: format)
            }
            queue.enqueue(item)
        }
        dismissPlaylistAnalysis()
    }

    public func choose(_ format: DownloadFormat, includeSubtitles: Bool = false, for item: DownloadItem) {
        item.format = format
        item.includeSubtitles = includeSubtitles
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
