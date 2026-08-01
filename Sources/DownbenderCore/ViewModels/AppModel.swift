import Foundation
import Observation

@MainActor @Observable
public final class AppModel {
    public static let destinationKey = "destinationPath"
    /// Where downloads land. Persisted; a vanished folder falls back to the init parameter.
    public var destination: URL {
        didSet { defaults.set(destination.path, forKey: Self.destinationKey) }
    }

    public static let maxConcurrentKey = "maxConcurrent"
    public var maxConcurrent: Int = 2 {
        didSet { defaults.set(maxConcurrent, forKey: Self.maxConcurrentKey) }
    }
    /// Drives the first-run terms sheet; observable so the UI reacts (termsAccepted is defaults-backed).
    public var showTerms: Bool = false

    public static let automaticAppUpdatesKey = "automaticAppUpdatesEnabled"
    /// When enabled, Downbender installs app updates but always leaves relaunching to the user.
    public var automaticAppUpdatesEnabled: Bool = false {
        didSet {
            defaults.set(automaticAppUpdatesEnabled, forKey: Self.automaticAppUpdatesKey)
            if automaticAppUpdatesEnabled, automaticAppUpdatesEnabled != oldValue {
                requestAutomaticAppUpdate()
            }
        }
    }

    public static let cookiesBrowserKey = "cookiesBrowser"
    /// Browser to borrow cookies from (nil = none); passed per invocation so a Settings change applies to the very next probe/download.
    public var cookiesBrowser: BrowserKind? {
        didSet {
            if let cookiesBrowser { defaults.set(cookiesBrowser.rawValue, forKey: Self.cookiesBrowserKey) }
            else { defaults.removeObject(forKey: Self.cookiesBrowserKey) }
        }
    }

    public static let defaultQualityKey = "defaultQuality"
    /// Pre-selected quality for the chooser; with one-click on, confirmed videos skip the panel.
    public var defaultQuality: DownloadFormat? {
        didSet {
            if let defaultQuality { defaults.set(defaultQuality.id, forKey: Self.defaultQualityKey) }
            else { defaults.removeObject(forKey: Self.defaultQualityKey) }
        }
    }

    public static let oneClickKey = "oneClickDownload"
    public var oneClickDownload: Bool = false {
        didSet { defaults.set(oneClickDownload, forKey: Self.oneClickKey) }
    }

    public static let fileNameTemplateKey = "fileNameTemplate"
    public private(set) var fileNameTemplate: String = FileNameTemplate.defaultValue
    public static let lastCustomFileNameTemplateKey = "lastCustomFileNameTemplate"
    public private(set) var lastCustomFileNameTemplate: String?

    public static let termsAcceptedKey = "termsAcceptedVersion"
    public static let currentTermsVersion = "1"
    /// True once the user accepted the current terms version. Backed by the injected defaults.
    public var termsAccepted: Bool {
        get { defaults.string(forKey: Self.termsAcceptedKey) == Self.currentTermsVersion }
        set {
            if newValue { defaults.set(Self.currentTermsVersion, forKey: Self.termsAcceptedKey) }
            else { defaults.removeObject(forKey: Self.termsAcceptedKey) }
        }
    }
    public let clipboard = ClipboardWatcher()
    /// Shared by the main window and Settings so update progress and restart readiness never disappear.
    public let updater: UnifiedUpdater
    /// Stable/nightly selection and installation state shared by Settings and queue rows.
    public let engineController: YtdlpEngineController
    public private(set) var dismissedAppUpdateVersion: String?
    public private(set) var queue: QueueViewModel!

    private let stableProbe: ProbeService
    private let nightlyProbe: ProbeService
    private let stableCoordinator: DownloadCoordinator
    private let nightlyCoordinator: DownloadCoordinator
    private let directCoordinator: DirectDownloadCoordinator
    private let directDownloader = DirectDownloadService()
    private let directSessionFactory: @Sendable () -> URLSession
    private let tmpDirectory: URL
    private let defaults: UserDefaults
    private let notifier: CompletionNotifying?
    private let queuePersistence: QueuePersistence
    @ObservationIgnored private var automaticUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var didStartUpdateChecks = false

    public init(
        binaries: BundledBinaries,
        destination: URL,
        tmpDirectory: URL,
        appSupportDirectory: URL,
        cookiesBrowser: BrowserKind? = nil,
        notifier: CompletionNotifying? = nil,
        runner: ProcessRunning = ProcessRunner(),
        defaults: UserDefaults = .standard,
        updater: UnifiedUpdater? = nil,
        engineController: YtdlpEngineController? = nil,
        directSessionFactory: @escaping @Sendable () -> URLSession = { DirectDownloadService.makeSession() }
    ) {
        // Observers don't fire during init: restoring persisted values writes nothing back.
        var isDirectory: ObjCBool = false
        if let savedPath = defaults.string(forKey: Self.destinationKey),
           FileManager.default.fileExists(atPath: savedPath, isDirectory: &isDirectory), isDirectory.boolValue {
            self.destination = URL(fileURLWithPath: savedPath)
        } else {
            self.destination = destination
        }
        let savedConcurrent = defaults.integer(forKey: Self.maxConcurrentKey)
        if (1...4).contains(savedConcurrent) { self.maxConcurrent = savedConcurrent }
        self.automaticAppUpdatesEnabled = defaults.bool(forKey: Self.automaticAppUpdatesKey)
        self.defaultQuality = defaults.string(forKey: Self.defaultQualityKey).flatMap(DownloadFormat.init(id:))
        self.oneClickDownload = defaults.bool(forKey: Self.oneClickKey)
        self.fileNameTemplate = defaults.string(forKey: Self.fileNameTemplateKey)
            .flatMap(FileNameTemplate.normalized) ?? FileNameTemplate.defaultValue
        if let savedCustom = defaults.string(forKey: Self.lastCustomFileNameTemplateKey),
           let normalizedCustom = FileNameTemplate.normalized(savedCustom),
           FileNameTemplate.Preset.matching(normalizedCustom) == nil {
            self.lastCustomFileNameTemplate = normalizedCustom
        } else {
            self.lastCustomFileNameTemplate = nil
            defaults.removeObject(forKey: Self.lastCustomFileNameTemplateKey)
        }
        self.tmpDirectory = tmpDirectory
        self.defaults = defaults
        self.notifier = notifier
        self.cookiesBrowser = cookiesBrowser
        self.queuePersistence = QueuePersistence(fileURL: appSupportDirectory.appendingPathComponent("queue.json"))
        let engine = UpdaterService(appSupportDirectory: appSupportDirectory)
        let nightlyURL = BinaryLocator.nightlyYtdlpURL(appSupportDirectory: appSupportDirectory)
        if let engineController {
            self.engineController = engineController
        } else {
            self.engineController = YtdlpEngineController(
                stableURL: binaries.ytdlp,
                nightlyURL: nightlyURL,
                defaults: defaults,
                readVersion: { url in
                    try await engine.installedVersion(runner: runner, ytdlpURL: url)
                },
                installLatestNightly: { onProgress in
                    let installed = try await engine.installLatestNightly(
                        runner: runner,
                        onProgress: onProgress
                    )
                    return YtdlpEngineInstallation(
                        executableURL: installed.binaryURL,
                        version: installed.version
                    )
                }
            )
        }
        if let updater {
            self.updater = updater
        } else {
            let selfUpdater = AppSelfUpdater(
                runner: runner,
                installURL: Bundle.main.bundleURL,
                expectedBundleID: Bundle.main.bundleIdentifier ?? "com.naztirs.downbender",
                appSupportDirectory: appSupportDirectory
            )
            self.updater = UnifiedUpdater(
                installedAppVersion: Downbender.version,
                fetchLatestAppTag: {
                    try await UpdaterService.latestVersion(from: AppUpdateChecker.releaseAPIURL)
                },
                updateApp: { onProgress in
                    try await selfUpdater.update(onProgress: onProgress)
                }
            )
        }
        self.stableProbe = ProbeService(
            runner: runner,
            ytdlpURL: self.engineController.stableURL,
            denoURL: binaries.deno
        )
        self.nightlyProbe = ProbeService(
            runner: runner,
            ytdlpURL: self.engineController.nightlyURL,
            denoURL: binaries.deno
        )
        let stableDownload = DownloadService(
            runner: runner,
            ytdlpURL: self.engineController.stableURL,
            ffmpegDirectory: binaries.ffmpegDirectory,
            denoURL: binaries.deno
        )
        let nightlyDownload = DownloadService(
            runner: runner,
            ytdlpURL: self.engineController.nightlyURL,
            ffmpegDirectory: binaries.ffmpegDirectory,
            denoURL: binaries.deno
        )
        let inspector = MediaInspector(
            runner: runner, ffprobeURL: binaries.ffmpegDirectory.appendingPathComponent("ffprobe")
        )
        self.stableCoordinator = DownloadCoordinator(
            download: stableDownload,
            inspect: inspector.videoDimensions(of:)
        )
        self.nightlyCoordinator = DownloadCoordinator(
            download: nightlyDownload,
            inspect: inspector.videoDimensions(of:)
        )
        self.directSessionFactory = directSessionFactory
        self.directCoordinator = DirectDownloadCoordinator(service: DirectDownloadService(), maxBytes: nil, sessionFactory: directSessionFactory)
        let stable = self.stableCoordinator
        let nightly = self.nightlyCoordinator
        let direct = self.directCoordinator
        self.queue = QueueViewModel(maxConcurrent: maxConcurrent, perform: { [weak self] item in
            switch item.source {
            case .media:
                guard let self else { return }
                let engine = await self.resolveEngine(for: item)
                guard !Task.isCancelled else { return }
                item.lastEngineChannel = engine.channel
                let coordinator = engine.channel == .nightly
                    ? nightly
                    : stable
                await coordinator.run(
                    item,
                    tmpDirectory: tmpDirectory,
                    cookiesBrowser: self.cookiesBrowser?.rawValue
                )
            case .directFile, .ambiguous:
                await direct.run(item, tmpDirectory: tmpDirectory,
                                 allowInsecureHTTP: self?.httpConfirmed.contains(item.id) == true)
            }
            switch item.state {
            case .done:
                self?.notifier?.downloadFinished(title: item.title, success: true, filePath: item.deliveredFileURL?.path)
            case .failed:
                self?.notifier?.downloadFinished(title: item.title, success: false, filePath: nil)
            default:
                break   // paused/cancelled are intentional user actions: no notification
            }
        })
        self.showTerms = (defaults.string(forKey: Self.termsAcceptedKey) != Self.currentTermsVersion)
        self.queue.onMutation = { [weak self] in self?.queueDidMutate() }
    }

    @discardableResult
    public func setFileNameTemplate(_ value: String) -> Bool {
        guard let normalized = FileNameTemplate.normalized(value) else { return false }
        rememberCustomFileNameTemplate(fileNameTemplate)
        fileNameTemplate = normalized
        defaults.set(normalized, forKey: Self.fileNameTemplateKey)
        rememberCustomFileNameTemplate(normalized)
        return true
    }

    public func resetFileNameTemplate() {
        rememberCustomFileNameTemplate(fileNameTemplate)
        fileNameTemplate = FileNameTemplate.defaultValue
        defaults.removeObject(forKey: Self.fileNameTemplateKey)
    }

    private func rememberCustomFileNameTemplate(_ value: String) {
        guard let normalized = FileNameTemplate.normalized(value),
              FileNameTemplate.Preset.matching(normalized) == nil
        else { return }
        lastCustomFileNameTemplate = normalized
        defaults.set(normalized, forKey: Self.lastCustomFileNameTemplateKey)
    }

    func queueDidMutate() {
        queuePersistence.scheduleSave(queue.items)
        // Opportunistic cleanup: the moment nothing could reuse its .part files, reclaim the space.
        if !hasResumableMediaItems { sweepTemporary() }
    }

    /// True while any media item could still reuse its .part files after a relaunch.
    var hasResumableMediaItems: Bool {
        queue.items.contains { item in
            item.source == .media &&
                (item.state == .paused || item.state == .queued || item.state == .downloading || item.state == .merging)
        }
    }

    public func sweepTemporary() {
        TempCleaner.sweep(tmpDirectory: tmpDirectory, keepResumables: hasResumableMediaItems)
    }

    /// Writes the queue synchronously — the quit flow's last word.
    public func saveQueueNow() {
        queuePersistence.saveNow(queue.items)
    }

    /// Rehydrates the persisted queue (interrupted work paused, probes re-run). Called once
    /// from the app at launch — NOT from init, so tests opt in explicitly.
    public func restoreQueue() {
        for persisted in queuePersistence.load() {
            let item = persisted.makeItem()
            queue.add(item)
            if item.state == .probing { runProbe(for: item) }
        }
        queueDidMutate()
    }

    /// Pause-everything + final save; the app delegate awaits this before quitting so no
    /// yt-dlp/ffmpeg child outlives the app.
    public func prepareForTermination() async {
        queue.pauseAllActive()
        let deadline = ContinuousClock.now + .seconds(3)
        while queue.hasLiveTasks, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        saveQueueNow()
    }

    /// Delay between silent probe retries on transient failures (tests shrink it).
    var probeRetryDelay: Duration = .seconds(2)

    /// In-flight probe tasks, per item: cancelled if the user removes the card.
    private var probeTasks: [UUID: Task<Void, Never>] = [:]
    /// In-flight HEAD tasks for direct files, per item: cancelled if the user removes the card.
    private var headTasks: [UUID: Task<Void, Never>] = [:]
    /// Direct items whose insecure-http download the user explicitly confirmed.
    private var httpConfirmed: Set<UUID> = []

    /// Watch links that also carry a `list=`: handled in arrival order so a multi-URL
    /// paste/drop never overwrites an earlier scope choice.
    private var pendingPlaylistChoices: [String] = []
    public var pendingPlaylistChoice: String? { pendingPlaylistChoices.first }

    /// Creates the card immediately ("probing" state) and probes in a background Task, one per URL.
    /// Watch+list URLs stop first at a scope prompt (RootView) instead of probing right away.
    @discardableResult
    public func addURL(_ url: String) -> Bool {
        if MediaURL.pointsToVideoInPlaylist(url) {
            pendingPlaylistChoices.append(url)
            return false
        }
        switch DetectionService.classify(url) {
        case .directFile: addDirectFileURL(url)
        case .mediaFile: addMediaFileURL(url)
        case .probe: addVideoURL(url)
        }
        return true
    }

    /// A clearly-a-file URL: create a probing card, HEAD for the size, then present the
    /// mini-confirmation (`.readyToChoose` + `.directFile`). No yt-dlp probe.
    private func addDirectFileURL(_ url: String) {
        let item = DownloadItem(url: url, title: URL(string: url)?.lastPathComponent ?? url,
                                destination: destination, state: .probing)
        item.source = .directFile(DirectFileInfo(suggestedName: URL(string: url)?.lastPathComponent))
        queue.add(item)
        headTasks[item.id] = Task { @MainActor [weak self] in
            defer { self?.headTasks[item.id] = nil }
            guard let self else { return }
            let info = try? await directDownloader.headInfo(url: url, session: directSessionFactory())
            guard !Task.isCancelled else { return }
            if let info {
                item.source = .directFile(info)
                if let name = info.suggestedName { item.title = name }
            }
            item.state = .readyToChoose
        }
    }

    /// A raw media file (.mp4/.mp3): let the user choose process-vs-raw. No probe until they pick.
    private func addMediaFileURL(_ url: String) {
        let item = DownloadItem(url: url, title: URL(string: url)?.lastPathComponent ?? url,
                                destination: destination, state: .readyToChoose)
        item.source = .ambiguous(DirectFileInfo(suggestedName: URL(string: url)?.lastPathComponent))
        queue.add(item)
    }

    public func chooseVideoOnly() {
        guard let url = pendingPlaylistChoice else { return }
        pendingPlaylistChoices.removeFirst()
        addVideoURL(url)
    }

    /// Expanding uses the SAME probing card as a single video (familiar feedback, retry
    /// included); the panel appears once the entry list is known.
    public func chooseWholePlaylist() {
        guard let url = pendingPlaylistChoice else { return }
        pendingPlaylistChoices.removeFirst()
        let item = DownloadItem(url: url, title: url, destination: destination, state: .probing)
        item.expandsPlaylist = true
        queue.add(item)
        runProbe(for: item)
    }

    public func dismissPlaylistChoice() {
        guard !pendingPlaylistChoices.isEmpty else { return }
        pendingPlaylistChoices.removeFirst()
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
            guard let self else { return }
            let engine = await resolveEngine(for: item)
            guard !Task.isCancelled else { return }
            item.lastEngineChannel = engine.channel
            let probe = probeService(for: engine.channel)
            let maxAttempts = 3
            for attempt in 1...maxAttempts {
                do {
                    let outcome = try await probe.probe(
                        url: item.url,
                        cookiesBrowser: cookiesBrowser?.rawValue,
                        expandPlaylist: item.expandsPlaylist
                    )
                    guard !Task.isCancelled else { return }
                    switch outcome {
                    case .video(let result):
                        item.title = result.title
                        item.thumbnailURL = result.thumbnailURL
                        item.probe = result
                        // The generic extractor matches almost any URL: treat it as ambiguous, not
                        // confirmed media, so the user gets the detection panel + "download as-is".
                        if result.isGeneric {
                            item.source = .ambiguous(DirectFileInfo(suggestedName: URL(string: item.url)?.lastPathComponent))
                        }
                        item.state = .readyToChoose
                        queueDidMutate()
                        // One-click: a CONFIRMED video (never generic/ambiguous) with a default
                        // quality set skips the chooser and goes straight to the queue.
                        if oneClickDownload, !result.isGeneric,
                           let preferred = defaultQuality,
                           let format = result.closestMatch(to: preferred) {
                            choose(format, for: item)
                        }
                    case .playlist(let playlist):
                        guard !playlist.entries.isEmpty else {
                            item.state = .probeFailed("Playlist is empty.")
                            queueDidMutate()
                            return
                        }
                        // The probing card becomes the playlist panel: one choice for all entries.
                        queue.remove(item)
                        presentAnalysis(playlist)
                    }
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    // Transient blips (DNS flaps, probe timeout) retry silently, like the download does.
                    if attempt < maxAttempts, TransientFailure.isTransient(error) {
                        try? await Task.sleep(for: self.probeRetryDelay)
                        if Task.isCancelled { return }
                        continue
                    }
                    // On a known media host (YouTube, Vimeo…) a probe failure is about that site — e.g.
                    // YouTube's cookie gate — NOT "it's a web page", so surface yt-dlp's own error (which
                    // YtdlpErrorHint turns into the cookies suggestion). Only HEAD-sniff unknown hosts.
                    if MediaURL.detect(in: item.url) == nil,
                       let info = try? await directDownloader.headInfo(url: item.url, session: directSessionFactory()), !Task.isCancelled {
                        if DirectDownloadService.isDownloadableContentType(info.contentType) {
                            // Fetchable file: reactivate the EXISTING card; no enqueue → no duplicate.
                            item.source = .directFile(info)
                            if let name = info.suggestedName { item.title = name }
                            item.state = .readyToChoose
                            queueDidMutate()
                            return
                        }
                        // Reachable but a web page (or other non-file): a clear message beats yt-dlp's raw error.
                        item.state = .probeFailed("This looks like a web page, not a video or a downloadable file.")
                        queueDidMutate()
                        return
                    }
                    guard !Task.isCancelled else { return }
                    item.state = .probeFailed(error.localizedDescription)
                    queueDidMutate()
                    return
                }
            }
        }
    }

    /// Live playlist analysis behind the panel sheet; non-nil while the sheet is up.
    public private(set) var playlistAnalysis: PlaylistAnalysis?
    private var analysisTask: Task<Void, Never>?

    /// Entry list of the analysis, once known (also what the older tests observe).
    public var pendingPlaylist: PlaylistProbe? { playlistAnalysis?.playlist }

    private func presentAnalysis(_ playlist: PlaylistProbe) {
        analysisTask?.cancel()
        let analysis = PlaylistAnalysis(playlist: playlist)
        playlistAnalysis = analysis
        analysisTask = Task { @MainActor [weak self] in
            await self?.calibrateEstimate(analysis)
        }
    }

    /// Closing the sheet (cancel or accept) stops any in-flight calibration probes.
    public func dismissPlaylistAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        playlistAnalysis = nil
    }

    /// Fully probes a SMALL sample of entries (sliding window) to replace the nominal
    /// bytes-per-second rate with a measured one. A sample, not the whole list: on a slow
    /// connection probing a 129-video mix would take minutes for a number that is an
    /// estimate anyway. The panel never waits on this.
    private func calibrateEstimate(_ analysis: PlaylistAnalysis) async {
        let entries = analysis.playlist.entries.prefix(8)
        guard !entries.isEmpty else { return }
        let engine = await engineController.resolveSelectedEngine()
        let probe = probeService(for: engine.channel)
        let cookies = cookiesBrowser?.rawValue
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
                if let result { analysis.sampleResults[url] = result }
                if nextIndex < entries.count {
                    let next = entries[nextIndex].url
                    nextIndex += 1
                    group.addTask { (next, (try? await probe.probe(url: next, cookiesBrowser: cookies))?.videoResult) }
                }
            }
            group.cancelAll()
        }
    }

    /// Backward-compatible all-entry acceptance. New callers that expose playlist selection
    /// should use the `selectedEntries` overload below.
    public func acceptPlaylist(_ playlist: PlaylistProbe, format: DownloadFormat, includeSubtitles: Bool = false) {
        acceptPlaylist(
            playlist,
            selectedEntries: playlist.entries,
            format: format,
            includeSubtitles: includeSubtitles
        )
    }

    /// Enqueues only the selected entries, in the exact order supplied by the caller. There is
    /// no blocking per-item probe; whatever the background estimation already learned travels
    /// with each item as its expected size.
    ///
    /// Empty selection is intentionally a no-op: the UI normally disables confirmation, while
    /// this guard keeps programmatic callers from dismissing the analysis without adding work.
    public func acceptPlaylist(
        _ playlist: PlaylistProbe,
        selectedEntries: [PlaylistEntry],
        format: DownloadFormat,
        includeSubtitles: Bool = false
    ) {
        guard !selectedEntries.isEmpty else { return }

        for entry in selectedEntries {
            let item = DownloadItem(
                url: entry.url,
                title: entry.title,
                thumbnailURL: entry.thumbnailURL,
                format: format,
                destination: destination,
                state: .queued
            )
            item.includeSubtitles = includeSubtitles && !format.isAudio
            item.fileNameTemplate = fileNameTemplate
            if let known = playlistAnalysis?.sampleResults[entry.url] {
                item.probe = known
                item.expectedTotalBytes = known.approxDownloadSize(for: format)
            }
            queue.enqueue(item)
        }
        dismissPlaylistAnalysis()
    }

    public func choose(_ format: DownloadFormat, includeSubtitles: Bool = false, for item: DownloadItem) {
        // Choosing a yt-dlp format means this is the media path (also flips an ambiguous card back).
        item.source = .media
        item.format = format
        item.includeSubtitles = includeSubtitles && !format.isAudio
        item.fileNameTemplate = fileNameTemplate
        item.destination = destination
        item.expectedTotalBytes = item.probe?.approxDownloadSize(for: format)
        queue.start(item)
    }

    /// User confirmed the mini-confirmation for a direct file.
    public func confirmDirect(_ item: DownloadItem) {
        item.destination = destination
        queue.startDirect(item)
    }

    /// True when a direct item's URL is plaintext http (needs an explicit confirmation).
    public func isInsecureHTTP(_ item: DownloadItem) -> Bool {
        URL(string: item.url)?.scheme?.lowercased() == "http"
    }

    /// Records the user's consent to download this insecure-http item.
    public func confirmInsecureHTTP(_ item: DownloadItem) { httpConfirmed.insert(item.id) }

    /// Ambiguous item: user chose "download as-is".
    public func downloadAmbiguousAsFile(_ item: DownloadItem) {
        if case .ambiguous(let info) = item.source { item.source = .directFile(info) }
        item.destination = destination
        queue.startDirect(item)
    }

    /// Ambiguous item: user chose "process with yt-dlp" — run the normal probe path.
    public func processAmbiguousAsMedia(_ item: DownloadItem) {
        item.source = .media
        item.state = .probing
        runProbe(for: item)
    }

    /// A site extractor failure can often be fixed by a freshly published nightly. Network,
    /// cookie, filesystem and direct-download errors deliberately keep their targeted actions.
    public func canTryLatestFixes(for item: DownloadItem) -> Bool {
        guard !engineController.isInstalling,
              item.source == .media, item.lastEngineChannel != .nightly,
              let message = failureMessage(for: item)
        else { return false }
        return YtdlpErrorHint.shouldOfferLatestFixes(for: message)
    }

    public func canRetryWithStable(_ item: DownloadItem) -> Bool {
        guard item.source == .media, item.lastEngineChannel == .nightly,
              let message = failureMessage(for: item)
        else { return false }
        return YtdlpErrorHint.shouldOfferLatestFixes(for: message)
    }

    /// Installs the newest official nightly transactionally, activates it, then retries the
    /// same card. If installation fails, the item and the previous engine choice are untouched.
    public func retryWithLatestFixes(_ item: DownloadItem) async throws {
        guard canTryLatestFixes(for: item) else { return }
        if engineController.selectedChannel == .nightly, engineController.nightlyInstalled {
            try await engineController.select(.nightly)
        } else {
            try await engineController.installLatestAndSelect()
        }
        guard queue.items.contains(where: { $0.id == item.id }) else { return }
        retryFailedItem(item, using: .nightly)
    }

    public func retryWithStable(_ item: DownloadItem) {
        guard canRetryWithStable(item) else { return }
        engineController.useStable()
        retryFailedItem(item, using: .stable)
    }

    private func retryFailedItem(_ item: DownloadItem, using channel: YtdlpEngineChannel) {
        switch item.state {
        case .probeFailed:
            item.nextEngineChannel = channel
            item.state = .probing
            runProbe(for: item)
        case .failed:
            item.nextEngineChannel = channel
            queue.retry(item)
        default:
            break
        }
    }

    private func failureMessage(for item: DownloadItem) -> String? {
        switch item.state {
        case .probeFailed(let message), .failed(let message): message
        default: nil
        }
    }

    private func probeService(for channel: YtdlpEngineChannel) -> ProbeService {
        channel == .nightly ? nightlyProbe : stableProbe
    }

    private func resolveEngine(for item: DownloadItem) async -> YtdlpEngineDescriptor {
        guard let channel = item.nextEngineChannel else {
            return await engineController.resolveSelectedEngine()
        }
        item.nextEngineChannel = nil
        return await engineController.resolveEngine(channel)
    }

    /// Removes the card from the list (cancelling any in-flight probe or download). Does not touch files.
    public func remove(_ item: DownloadItem) {
        probeTasks[item.id]?.cancel()
        probeTasks[item.id] = nil
        headTasks[item.id]?.cancel()
        headTasks[item.id] = nil
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

    /// Starts exactly one launch check. The automatic path owns its task, so closing a
    /// SwiftUI window cannot cancel an app update already in progress.
    public func startUpdateChecks() {
        guard !didStartUpdateChecks else { return }
        didStartUpdateChecks = true
        if automaticAppUpdatesEnabled {
            requestAutomaticAppUpdate()
        } else {
            Task { await updater.check() }
        }
    }

    /// A user-initiated refresh respects the automatic-app-update switch. The optional
    /// nightly engine has its own explicit control in Settings.
    public func checkForUpdates() async {
        if automaticAppUpdatesEnabled {
            await updater.checkAndInstallAppUpdate()
        } else {
            await updater.check()
        }
    }

    public func dismissAppUpdate(version: String) {
        dismissedAppUpdateVersion = version
    }

    private func requestAutomaticAppUpdate() {
        guard automaticUpdateTask == nil else { return }
        automaticUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await updater.checkAndInstallAppUpdate()
            automaticUpdateTask = nil
        }
    }
}
