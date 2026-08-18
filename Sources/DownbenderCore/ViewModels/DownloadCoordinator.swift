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
        cookiesBrowser: String? = nil,
        detailedDiagnostics: Bool = false
    ) async {
        // Defensive: pump() only starts items that went through start(), which requires a format.
        guard let format = item.format else {
            item.state = .failed("No format selected.")
            return
        }
        item.failureDiagnostics = nil
        item.state = .downloading
        let fileNameTemplate = item.fileNameTemplate
        var failedAttempts: [FailureAttempt] = []
        var formatFallbackAttempt: FailureAttempt?
        var useOriginalCodecMKV = false
        // YouTube 403s are intermittent: a FRESH yt-dlp invocation renegotiates the session's
        // signed URLs from scratch, so the manual retry that used to work is automated here.
        let maxTransientAttempts = 3
        var transientAttempt = 1
        var invocationNumber = 0
        while true {
            invocationNumber += 1
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
                    useTVClient: transientAttempt == maxTransientAttempts,
                    cookiesBrowser: cookiesBrowser,
                    fileNameTemplate: fileNameTemplate,
                    includeSubtitles: item.includeSubtitles,
                    detailedDiagnostics: detailedDiagnostics,
                    useOriginalCodecMKV: useOriginalCodecMKV,
                    expectedTotalBytes: useOriginalCodecMKV ? nil : item.expectedTotalBytes,
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

                // Stage delivery metadata until inspection finishes. A pause/cancel during
                // ffprobe must not leave a fallback warning attached to an unfinished item.
                var deliveredNote = useOriginalCodecMKV
                    ? "MP4 unavailable; saved as MKV"
                    : ""
                var deliveredMismatch = useOriginalCodecMKV

                // Honesty check: confirm exact requests and report the actual dimensions for Maximum.
                if let deliveredURL, let inspect {
                    switch format {
                    case .video(let height):
                        if let dims = await inspect(deliveredURL) {
                            let dimensionsNote: String
                            if dims.height == height {
                                dimensionsNote = "\(dims.width)×\(dims.height)"
                            } else {
                                dimensionsNote = "Requested \(height)p, got \(dims.height)p"
                                deliveredMismatch = true
                            }
                            deliveredNote = useOriginalCodecMKV
                                ? "\(deliveredNote) · \(dimensionsNote)"
                                : dimensionsNote
                        }
                    case .maximumVideo:
                        if let dims = await inspect(deliveredURL) {
                            deliveredNote = "\(dims.width)×\(dims.height)"
                        }
                    case .audioMP3, .audioM4A, .audioOpus:
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
                    // Delivered path is recorded for every format, including extracted audio.
                    if let deliveredURL { item.deliveredFileURL = deliveredURL }
                    item.deliveredNote = deliveredNote
                    item.deliveredMismatch = deliveredMismatch
                    item.state = .done
                }
                return
            } catch {
                progressUpdates.cancel()
                if Task.isCancelled {
                    finishInterrupted(item)
                    return
                }
                let failure = failureAttempt(
                    for: error,
                    number: invocationNumber,
                    detailed: detailedDiagnostics
                )
                failedAttempts.append(failure)
                let message = failure.summary
                if shouldFallBackToOriginalCodecMKV(
                    after: error,
                    format: format,
                    alreadyUsingFallback: useOriginalCodecMKV
                ) {
                    formatFallbackAttempt = failure
                    useOriginalCodecMKV = true
                    item.state = .downloading
                    item.fraction = 0
                    item.speedText = ""
                    item.etaText = ""
                    continue
                }
                if TransientFailure.isTransient(error), transientAttempt < maxTransientAttempts {
                    transientAttempt += 1
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
                // Reports stay bounded at three attempts, but the exact MP4 failure that
                // triggered the profile switch must survive even if a transient error came
                // first. Keep that trigger plus the two most recent other failures in order.
                let attemptsForDiagnostics: [FailureAttempt]
                if let formatFallbackAttempt, failedAttempts.count > 3 {
                    let recent = failedAttempts
                        .filter { $0.number != formatFallbackAttempt.number }
                        .suffix(2)
                    attemptsForDiagnostics = ([formatFallbackAttempt] + recent)
                        .sorted { $0.number < $1.number }
                } else {
                    attemptsForDiagnostics = failedAttempts
                }
                item.failureDiagnostics = FailureDiagnostics(
                    host: FailureDiagnostics.host(from: item.url),
                    operation: .download,
                    engineChannel: item.lastEngineChannel,
                    engineVersion: item.lastEngineVersion,
                    outputDescription: useOriginalCodecMKV
                        ? "\(format.preferenceLabel) · MP4 → MKV fallback"
                        : "\(format.preferenceLabel) · \(format.containerLabel)",
                    includeSubtitles: item.includeSubtitles,
                    attempts: attemptsForDiagnostics
                )
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

    private func failureAttempt(
        for error: Error,
        number: Int,
        detailed: Bool
    ) -> FailureAttempt {
        if let downloadError = error as? DownloadError,
           case .ytdlpFailed(let details) = downloadError {
            return FailureAttempt(
                number: number,
                exitCode: details.exitCode,
                detailed: detailed,
                summary: details.summary,
                output: details.output
            )
        }
        let message = error.localizedDescription
        return FailureAttempt(
            number: number,
            exitCode: nil,
            detailed: detailed,
            summary: message,
            output: message
        )
    }

    private func shouldFallBackToOriginalCodecMKV(
        after error: Error,
        format: DownloadFormat,
        alreadyUsingFallback: Bool
    ) -> Bool {
        guard !alreadyUsingFallback,
              case .video(let height) = format,
              height <= 1080,
              let downloadError = error as? DownloadError,
              case .ytdlpFailed(let details) = downloadError
        else { return false }
        return details.output.localizedCaseInsensitiveContains(
            "requested format is not available"
        )
    }
}
