import Foundation

protocol DirectDownloading: Sendable {
    // Mirrors DirectDownloadService's complete transfer boundary.
    // swiftlint:disable:next function_parameter_count
    func download(
        url: String,
        destination: URL,
        tmpDirectory: URL,
        suggestedName: String?,
        maxBytes: Int64?,
        allowInsecureHTTP: Bool,
        resumeData: Data?,
        session: URLSession,
        onProgress: @Sendable @escaping (DownloadProgress) -> Void,
        onResumeData: (@Sendable (Data) -> Void)?
    ) async throws -> URL
}

extension DirectDownloadService: DirectDownloading {}

/// Orchestrates a direct (non-yt-dlp) download for one item: mirrors DownloadCoordinator's
/// item-state bookkeeping but calls DirectDownloadService instead of spawning yt-dlp.
@MainActor
public final class DirectDownloadCoordinator {
    let service: any DirectDownloading
    let maxBytes: Int64?
    let retryDelay: Duration
    let sessionFactory: @Sendable () -> URLSession
    let progressInterval: Duration
    let progressSleep: ProgressCoalescer.Sleep

    public init(
        service: DirectDownloadService,
        maxBytes: Int64?,
        retryDelay: Duration = .seconds(3),
        sessionFactory: @escaping @Sendable () -> URLSession = { DirectDownloadService.makeSession() }
    ) {
        self.service = service
        self.maxBytes = maxBytes
        self.retryDelay = retryDelay
        self.sessionFactory = sessionFactory
        self.progressInterval = ProgressCoalescer.defaultInterval
        self.progressSleep = { duration in try? await Task.sleep(for: duration) }
    }

    init(
        downloader: any DirectDownloading,
        maxBytes: Int64?,
        retryDelay: Duration = .seconds(3),
        sessionFactory: @escaping @Sendable () -> URLSession = { DirectDownloadService.makeSession() },
        progressInterval: Duration,
        progressSleep: @escaping ProgressCoalescer.Sleep
    ) {
        self.service = downloader
        self.maxBytes = maxBytes
        self.retryDelay = retryDelay
        self.sessionFactory = sessionFactory
        self.progressInterval = progressInterval
        self.progressSleep = progressSleep
    }

    public func run(_ item: DownloadItem, tmpDirectory: URL, allowInsecureHTTP: Bool = false) async {
        item.failureDiagnostics = nil
        item.state = .downloading
        if let known = knownSize(item), let free = freeCapacity(at: item.destination), known > free {
            let message = DirectDownloadError.notEnoughDiskSpace.localizedDescription
            item.failureDiagnostics = directDiagnostics(
                for: item,
                attempts: [FailureAttempt(
                    number: 1,
                    exitCode: nil,
                    detailed: false,
                    summary: message,
                    output: message
                )]
            )
            item.state = .failed(message)
            return
        }
        let suggested: String? = {
            switch item.source {
            case .directFile(let info), .ambiguous(let info): return info.suggestedName
            case .media: return nil
            }
        }()
        // Same shape as DownloadCoordinator: transient network blips get fresh attempts.
        let maxAttempts = 3
        var failedAttempts: [FailureAttempt] = []
        for attempt in 1...maxAttempts {
            let session = sessionFactory()
            let progressUpdates = ProgressCoalescer(
                interval: progressInterval,
                sleep: progressSleep
            ) { progress in
                guard item.state == .downloading else { return }
                item.indeterminateProgress = progress.fraction < 1 && progress.totalBytes == nil
                item.fraction = progress.fraction
                item.speedText = progress.speedText
                item.etaText = progress.etaText
            }
            do {
                let delivered = try await service.download(
                    url: item.url, destination: item.destination, tmpDirectory: tmpDirectory,
                    suggestedName: suggested, maxBytes: maxBytes, allowInsecureHTTP: allowInsecureHTTP,
                    resumeData: item.resumeData, session: session,
                    onProgress: { progress in
                        progressUpdates.submit(progress)
                    },
                    onResumeData: { data in
                        // Captured on pause/interruption; resume() hands it back to URLSession.
                        Task { @MainActor in item.resumeData = data }
                    }
                )
                item.resumeData = nil
                item.indeterminateProgress = false
                item.deliveredFileURL = delivered
                if Task.isCancelled {
                    progressUpdates.cancel()
                    finishInterrupted(item)
                } else {
                    progressUpdates.finish()
                    item.state = .done
                }
                return
            } catch {
                progressUpdates.cancel()
                item.indeterminateProgress = false
                if Task.isCancelled || error is CancellationError {
                    finishInterrupted(item)
                    // A real cancel discards the partial transfer; only pause keeps resume data.
                    if item.state == .cancelled { item.resumeData = nil }
                    return
                }
                item.resumeData = nil
                let message = error.localizedDescription
                failedAttempts.append(FailureAttempt(
                    number: attempt,
                    exitCode: nil,
                    detailed: false,
                    summary: message,
                    output: message
                ))
                if let urlError = error as? URLError,
                   TransientFailure.transientURLCodes.contains(urlError.code), attempt < maxAttempts {
                    item.fraction = 0
                    item.speedText = ""
                    item.etaText = ""
                    try? await Task.sleep(for: retryDelay)
                    if Task.isCancelled { finishInterrupted(item); return }
                    continue
                }
                item.failureDiagnostics = directDiagnostics(for: item, attempts: failedAttempts)
                item.state = .failed(failedAttempts.last?.summary ?? "The download failed.")
                return
            }
        }
    }

    /// Same convention as DownloadCoordinator: QueueViewModel set .paused/.cancelled BEFORE
    /// cancelling the Task, so only an execution state gets overwritten here.
    private func finishInterrupted(_ item: DownloadItem) {
        if item.state == .downloading { item.state = .cancelled }
    }

    private func directDiagnostics(
        for item: DownloadItem,
        attempts: [FailureAttempt]
    ) -> FailureDiagnostics {
        FailureDiagnostics(
            host: FailureDiagnostics.host(from: item.url),
            operation: .directDownload,
            engineChannel: nil,
            engineVersion: nil,
            outputDescription: "Direct file",
            includeSubtitles: nil,
            attempts: attempts
        )
    }

    private func knownSize(_ item: DownloadItem) -> Int64? {
        switch item.source {
        case .directFile(let info), .ambiguous(let info): info.sizeBytes
        case .media: nil
        }
    }

    /// Free space on the destination's volume (not tmp's — they can differ; the atomic move
    /// lands on the destination volume).
    private func freeCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
