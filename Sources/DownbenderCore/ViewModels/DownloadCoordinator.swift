import Foundation

@MainActor
public final class DownloadCoordinator {
    let download: DownloadService
    let inspect: (@Sendable (URL) async -> (width: Int, height: Int)?)?
    let retryDelay: Duration
    let progressInterval: Duration
    let progressSleep: ProgressCoalescer.Sleep

    public init(
        download: DownloadService,
        inspect: (@Sendable (URL) async -> (width: Int, height: Int)?)? = nil,
        retryDelay: Duration = .seconds(3)
    ) {
        self.download = download
        self.inspect = inspect
        self.retryDelay = retryDelay
        self.progressInterval = ProgressCoalescer.defaultInterval
        self.progressSleep = { duration in try? await Task.sleep(for: duration) }
    }

    init(
        download: DownloadService,
        inspect: (@Sendable (URL) async -> (width: Int, height: Int)?)? = nil,
        retryDelay: Duration = .seconds(3),
        progressInterval: Duration,
        progressSleep: @escaping ProgressCoalescer.Sleep
    ) {
        self.download = download
        self.inspect = inspect
        self.retryDelay = retryDelay
        self.progressInterval = progressInterval
        self.progressSleep = progressSleep
    }

    public func run(
        _ item: DownloadItem,
        tmpDirectory: URL,
        cookiesBrowser: String? = nil
    ) async {
        // Defensive: pump() only starts items that went through start(), which requires a format.
        guard let format = item.format else {
            item.state = .failed("No format selected.")
            return
        }
        item.state = .downloading
        let fileNameTemplate = item.fileNameTemplate
        // YouTube 403s are intermittent: a FRESH yt-dlp invocation renegotiates the session's
        // signed URLs from scratch, so the manual retry that used to work is automated here.
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            let progressUpdates = ProgressCoalescer(
                interval: progressInterval,
                sleep: progressSleep
            ) { progress in
                guard item.state == .downloading
                    || (item.state == .merging && progress.fraction >= 1)
                else { return }
                item.fraction = progress.fraction
                item.speedText = progress.speedText
                item.etaText = progress.etaText
            }
            do {
                let deliveredURL = try await download.download(
                    url: item.url,
                    format: format,
                    destination: item.destination,
                    tmpDirectory: tmpDirectory,
                    // The FINAL attempt escalates to the TV client (dodges the persistent PO-token 403).
                    useTVClient: attempt == maxAttempts,
                    cookiesBrowser: cookiesBrowser,
                    fileNameTemplate: fileNameTemplate,
                    includeSubtitles: item.includeSubtitles,
                    expectedTotalBytes: item.expectedTotalBytes,
                    onProgress: { progress in
                        progressUpdates.submit(progress)
                    },
                    onMerging: {
                        Task { @MainActor in
                            guard progressUpdates.isActive else { return }
                            if item.state == .downloading { item.state = .merging }
                        }
                    }
                )

                // Delivered path recorded for ALL formats (DBPATH is printed for MP3 too): enables "reveal in Finder".
                if let deliveredURL { item.deliveredFileURL = deliveredURL }

                // Honesty check: confirm exact requests and report the actual dimensions for Maximum.
                if let deliveredURL, let inspect {
                    switch format {
                    case .video(let height):
                        if let dims = await inspect(deliveredURL) {
                            if dims.height == height {
                                item.deliveredNote = "\(dims.width)×\(dims.height)"
                            } else {
                                item.deliveredNote = "Requested \(height)p, got \(dims.height)p"
                                item.deliveredMismatch = true
                            }
                        }
                    case .maximumVideo:
                        if let dims = await inspect(deliveredURL) {
                            item.deliveredNote = "\(dims.width)×\(dims.height)"
                        }
                    case .audioMP3:
                        break
                    }
                }

                // The inspection is a suspension point: a cancel/pause while ffprobe runs (inspect
                // returns nil without propagating the error) must not end up as .done.
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
                if Task.isCancelled {
                    finishInterrupted(item)
                    return
                }
                let message = error.localizedDescription
                if TransientFailure.isTransient(error), attempt < maxAttempts {
                    // Reset progress AND state: the failed attempt may have reached .merging, and without
                    // returning to .downloading the hop guards would discard all of the retry's progress.
                    item.state = .downloading
                    item.fraction = 0
                    item.speedText = ""
                    item.etaText = ""
                    try? await Task.sleep(for: retryDelay)
                    if Task.isCancelled {
                        finishInterrupted(item)
                        return
                    }
                    continue
                }
                item.state = .failed(message)
                return
            }
        }
    }

    /// Pause and cancel share a mechanism (cancelling the Task); the state QueueViewModel set
    /// BEFORE cancelling encodes the intent, so only execution states get overwritten here.
    private func finishInterrupted(_ item: DownloadItem) {
        if item.state == .downloading || item.state == .merging { item.state = .cancelled }
    }
}
