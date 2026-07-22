import Foundation

/// Orchestrates a direct (non-yt-dlp) download for one item: mirrors DownloadCoordinator's
/// item-state bookkeeping but calls DirectDownloadService instead of spawning yt-dlp.
@MainActor
public final class DirectDownloadCoordinator {
    let service: DirectDownloadService
    let maxBytes: Int64?
    let retryDelay: Duration
    let sessionFactory: @Sendable () -> URLSession

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
    }

    public func run(_ item: DownloadItem, tmpDirectory: URL, allowInsecureHTTP: Bool = false) async {
        item.state = .downloading
        if let known = knownSize(item), let free = freeCapacity(at: item.destination), known > free {
            item.state = .failed(DirectDownloadError.notEnoughDiskSpace.localizedDescription)
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
        for attempt in 1...maxAttempts {
            let session = sessionFactory()
            do {
                let delivered = try await service.download(
                    url: item.url, destination: item.destination, tmpDirectory: tmpDirectory,
                    suggestedName: suggested, maxBytes: maxBytes, allowInsecureHTTP: allowInsecureHTTP,
                    resumeData: item.resumeData, session: session,
                    onProgress: { progress in
                        Task { @MainActor in
                            if item.state == .downloading {
                                item.indeterminateProgress = progress.totalBytes == nil
                                item.fraction = progress.fraction
                                item.speedText = progress.speedText
                                item.etaText = progress.etaText
                            }
                        }
                    },
                    onResumeData: { data in
                        // Captured on pause/interruption; resume() hands it back to URLSession.
                        Task { @MainActor in item.resumeData = data }
                    }
                )
                item.resumeData = nil
                item.indeterminateProgress = false
                item.deliveredFileURL = delivered
                if Task.isCancelled { finishInterrupted(item) } else { item.state = .done }
                return
            } catch {
                item.indeterminateProgress = false
                if Task.isCancelled || error is CancellationError {
                    finishInterrupted(item)
                    // A real cancel discards the partial transfer; only pause keeps resume data.
                    if item.state == .cancelled { item.resumeData = nil }
                    return
                }
                item.resumeData = nil
                if let urlError = error as? URLError,
                   TransientFailure.transientURLCodes.contains(urlError.code), attempt < maxAttempts {
                    item.fraction = 0
                    item.speedText = ""
                    item.etaText = ""
                    try? await Task.sleep(for: retryDelay)
                    if Task.isCancelled { finishInterrupted(item); return }
                    continue
                }
                item.state = .failed(error.localizedDescription)
                return
            }
        }
    }

    /// Same convention as DownloadCoordinator: QueueViewModel set .paused/.cancelled BEFORE
    /// cancelling the Task, so only an execution state gets overwritten here.
    private func finishInterrupted(_ item: DownloadItem) {
        if item.state == .downloading { item.state = .cancelled }
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
