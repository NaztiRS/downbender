import Foundation

/// Orchestrates a direct (non-yt-dlp) download for one item: mirrors DownloadCoordinator's
/// item-state bookkeeping but calls DirectDownloadService instead of spawning yt-dlp.
@MainActor
public final class DirectDownloadCoordinator {
    let service: DirectDownloadService
    let maxBytes: Int64?
    let sessionFactory: @Sendable () -> URLSession

    public init(
        service: DirectDownloadService,
        maxBytes: Int64?,
        sessionFactory: @escaping @Sendable () -> URLSession = { DirectDownloadService.makeSession() }
    ) {
        self.service = service
        self.maxBytes = maxBytes
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
        let session = sessionFactory()
        do {
            let delivered = try await service.download(
                url: item.url, destination: item.destination, tmpDirectory: tmpDirectory,
                suggestedName: suggested, maxBytes: maxBytes, allowInsecureHTTP: allowInsecureHTTP, session: session,
                onProgress: { progress in
                    Task { @MainActor in
                        if item.state == .downloading {
                            item.fraction = progress.fraction
                            item.speedText = progress.speedText
                            item.etaText = progress.etaText
                        }
                    }
                }
            )
            item.deliveredFileURL = delivered
            if Task.isCancelled { finishInterrupted(item) } else { item.state = .done }
        } catch {
            if Task.isCancelled { finishInterrupted(item); return }
            item.state = .failed(error.localizedDescription)
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
