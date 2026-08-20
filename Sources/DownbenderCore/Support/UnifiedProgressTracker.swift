import Foundation

/// Fuses yt-dlp's per-file progress (video, audio, merge) into one monotonic 0…1 fraction.
/// Mutated from ProcessRunner's stdout handler, hence the NSLock.
public final class UnifiedProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedTotalBytes: Int64?
    private let expectedPhases: Int
    private var plan: DownloadProgressPlan?
    private var completedBytes: Int64 = 0
    private var phaseBytes: Int64 = 0
    private var phaseTotal: Int64?
    private var phaseIndex = 0
    private var phaseSawProgress = false
    private var emitted: Double = 0

    /// expectedPhases = files yt-dlp will download (2 for bv*+ba, 1 for audio-only).
    public init(expectedTotalBytes: Int64?, expectedPhases: Int) {
        self.expectedTotalBytes = (expectedTotalBytes ?? 0) > 0 ? expectedTotalBytes : nil
        self.expectedPhases = max(1, expectedPhases)
    }

    /// Consolidates the previous phase on each "[download] Destination:"; a no-op until the first progress arrives.
    public func beginPhase() {
        lock.lock(); defer { lock.unlock() }
        guard phaseSawProgress else { return }
        completedBytes += phaseBytes
        phaseBytes = 0
        phaseTotal = nil
        phaseIndex += 1
        phaseSawProgress = false
    }

    func configure(with plan: DownloadProgressPlan) {
        lock.lock(); defer { lock.unlock() }
        self.plan = plan
    }

    public func unified(_ p: DownloadProgress) -> DownloadProgress {
        lock.lock(); defer { lock.unlock() }
        phaseSawProgress = true
        if let d = p.downloadedBytes { phaseBytes = max(phaseBytes, d) }
        if let t = p.totalBytes { phaseTotal = t }

        var raw: Double
        if let plan, !plan.phases.isEmpty {
            let index = min(phaseIndex, plan.phases.count - 1)
            let weights = plan.weights
            let completedWeight = weights.prefix(index).reduce(0, +)
            raw = completedWeight + phaseFraction(p, plannedSize: plan.phases[index].sizeBytes) * weights[index]
        } else if let expected = expectedTotalBytes, p.downloadedBytes != nil {
            // Denominator never drops below seen + remainder of the current file: a short estimate must not hit 100% early.
            let floorBytes = completedBytes + (phaseTotal ?? phaseBytes)
            raw = Double(completedBytes + phaseBytes) / Double(max(expected, max(floorBytes, 1)))
        } else {
            raw = weighted(fraction: p.fraction)
        }
        let phaseCount = plan?.phases.count ?? expectedPhases
        // A current phase cannot complete the whole operation while another selected stream remains.
        if phaseIndex + 1 < phaseCount { raw = min(raw, 0.999) }
        emitted = min(1, max(emitted, raw))
        return DownloadProgress(
            fraction: emitted, speedText: p.speedText, etaText: p.etaText,
            downloadedBytes: p.downloadedBytes, totalBytes: p.totalBytes,
            status: p.status, fragmentIndex: p.fragmentIndex, fragmentCount: p.fragmentCount
        )
    }

    private func phaseFraction(_ progress: DownloadProgress, plannedSize: Int64?) -> Double {
        if progress.status == .finished { return 1 }

        if let index = progress.fragmentIndex,
           let count = progress.fragmentCount,
           index >= 0, count > 0 {
            return min(Double(index) / Double(count), 0.999)
        }

        let denominator = plannedSize ?? progress.totalBytes
        if let downloaded = progress.downloadedBytes, let denominator, denominator > 0 {
            let fraction = Double(downloaded) / Double(denominator)
            return progress.status == .downloading
                ? min(max(fraction, 0), 0.999)
                : min(max(fraction, 0), 1)
        }

        return progress.status == .downloading
            ? min(max(progress.fraction, 0), 0.999)
            : min(max(progress.fraction, 0), 1)
    }

    /// Last-resort behavior for output without a DBPLAN line: divide phases evenly.
    private func weighted(fraction: Double) -> Double {
        guard expectedPhases > 1 else { return fraction }
        let phaseWeight = 1 / Double(expectedPhases)
        return min(1, Double(phaseIndex) * phaseWeight + fraction * phaseWeight)
    }
}
