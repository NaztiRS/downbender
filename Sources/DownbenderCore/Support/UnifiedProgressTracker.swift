import Foundation

/// Fuses yt-dlp's per-file progress (video, audio, merge) into one monotonic 0…1 fraction.
/// Mutated from ProcessRunner's stdout handler, hence the NSLock.
public final class UnifiedProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedTotalBytes: Int64?
    private let expectedPhases: Int
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

    public func unified(_ p: DownloadProgress) -> DownloadProgress {
        lock.lock(); defer { lock.unlock() }
        phaseSawProgress = true
        if let d = p.downloadedBytes { phaseBytes = max(phaseBytes, d) }
        if let t = p.totalBytes { phaseTotal = t }

        var raw: Double
        if let expected = expectedTotalBytes, p.downloadedBytes != nil {
            // Denominator never drops below seen + remainder of the current file: a short estimate must not hit 100% early.
            let floorBytes = completedBytes + (phaseTotal ?? phaseBytes)
            raw = Double(completedBytes + phaseBytes) / Double(max(expected, max(floorBytes, 1)))
        } else {
            raw = weighted(fraction: p.fraction)
        }
        // Phases still pending (the audio): cap below 100% even if the estimate fell short.
        if phaseIndex + 1 < expectedPhases { raw = min(raw, 0.97) }
        emitted = min(1, max(emitted, raw))
        return DownloadProgress(
            fraction: emitted, speedText: p.speedText, etaText: p.etaText,
            downloadedBytes: p.downloadedBytes, totalBytes: p.totalBytes
        )
    }

    /// Fallback without bytes: the video (phase 0) takes 85 % of the bar and the audio the rest.
    private func weighted(fraction: Double) -> Double {
        guard expectedPhases > 1 else { return fraction }
        let videoWeight = 0.85
        switch phaseIndex {
        case 0: return fraction * videoWeight
        case 1: return videoWeight + fraction * (1 - videoWeight)
        default: return 1
        }
    }
}
