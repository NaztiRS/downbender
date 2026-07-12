import Testing
import Foundation
@testable import DownbenderCore

/// Thread-safe fraction sink to observe the emitted progress (box+NSLock pattern).
final class FractionSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ v: Double) { lock.lock(); storage.append(v); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}

private func progress(_ fraction: Double, downloaded: Int64? = nil, total: Int64? = nil) -> DownloadProgress {
    DownloadProgress(fraction: fraction, speedText: "", etaText: "", downloadedBytes: downloaded, totalBytes: total)
}

@Test func trackerUnifiesTwoPhasesWithBytesAndExpectedTotal() {
    let t = UnifiedProgressTracker(expectedTotalBytes: 100_000_000, expectedPhases: 2)
    t.beginPhase()  // Destination of the FIRST file: no-op (no progress yet)
    #expect(abs(t.unified(progress(0.5, downloaded: 40_000_000, total: 80_000_000)).fraction - 0.4) < 0.0001)
    #expect(abs(t.unified(progress(1.0, downloaded: 80_000_000, total: 80_000_000)).fraction - 0.8) < 0.0001)
    t.beginPhase()
    #expect(abs(t.unified(progress(0.5, downloaded: 10_000_000, total: 20_000_000)).fraction - 0.9) < 0.0001)
    #expect(abs(t.unified(progress(1.0, downloaded: 20_000_000, total: 20_000_000)).fraction - 1.0) < 0.0001)
}

@Test func trackerNeverGoesBackwards() {
    let t = UnifiedProgressTracker(expectedTotalBytes: nil, expectedPhases: 1)
    #expect(abs(t.unified(progress(0.8)).fraction - 0.8) < 0.0001)
    // yt-dlp may re-emit a lower percentage (e.g. when retrying a fragment)
    #expect(abs(t.unified(progress(0.5)).fraction - 0.8) < 0.0001)
}

@Test func trackerCapsBelowFullWhilePhasesRemain() {
    // Short estimate (50 MB) vs. real video (80 MB): without the cap the bar would hit 100% with the audio pending.
    let t = UnifiedProgressTracker(expectedTotalBytes: 50_000_000, expectedPhases: 2)
    let f = t.unified(progress(1.0, downloaded: 80_000_000, total: 80_000_000)).fraction
    #expect(f <= 0.97)
    t.beginPhase()
    let g = t.unified(progress(1.0, downloaded: 20_000_000, total: 20_000_000)).fraction
    #expect(abs(g - 1.0) < 0.0001)
}

@Test func trackerWeightsPhasesWithoutBytes() {
    let t = UnifiedProgressTracker(expectedTotalBytes: nil, expectedPhases: 2)
    #expect(abs(t.unified(progress(0.5)).fraction - 0.425) < 0.0001)   // video: 50% of 0.85
    #expect(abs(t.unified(progress(1.0)).fraction - 0.85) < 0.0001)
    t.beginPhase()  // advances even without bytes: it saw progress in the previous phase
    #expect(abs(t.unified(progress(1.0)).fraction - 1.0) < 0.0001)
}

@Test func trackerSinglePhasePassesFractionThrough() {
    let t = UnifiedProgressTracker(expectedTotalBytes: nil, expectedPhases: 1)
    t.beginPhase()
    #expect(abs(t.unified(progress(0.3)).fraction - 0.3) < 0.0001)
    #expect(abs(t.unified(progress(1.0)).fraction - 1.0) < 0.0001)
}
