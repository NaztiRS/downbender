import Foundation
import Observation

/// Live model behind the playlist panel. The size estimate is INSTANT — total duration of
/// the entries × a typical bytes-per-second rate per quality — and gets calibrated in the
/// background by fully probing a small sample of entries (probing all of them would take
/// minutes on a slow connection; the panel must never make the user wait).
@MainActor @Observable
public final class PlaylistAnalysis {
    public let playlist: PlaylistProbe
    /// Full probes of the calibration sample, keyed by entry URL; fills in progressively.
    public internal(set) var sampleResults: [String: ProbeResult] = [:]

    public init(playlist: PlaylistProbe) {
        self.playlist = playlist
    }

    /// nil only when no entry has a duration and nothing has been sampled yet.
    public func estimatedTotalBytes(for format: DownloadFormat) -> Int64? {
        let durations = playlist.entries.compactMap(\.durationSeconds)
        let rate = measuredRate(for: format) ?? Self.nominalRate(for: format)
        if durations.isEmpty {
            // No durations (rare outside YouTube): extrapolate the sampled average per video.
            guard !sampleResults.isEmpty else { return nil }
            let sizes = sampleResults.values.compactMap { $0.approxDownloadSize(for: format) }
            guard !sizes.isEmpty else { return nil }
            let average = sizes.reduce(0, +) / Int64(sizes.count)
            return average * Int64(playlist.entries.count)
        }
        // Entries without a duration count as an average-length video.
        let known = durations.reduce(0, +)
        let average = known / Double(durations.count)
        let total = known + average * Double(playlist.entries.count - durations.count)
        return Int64(total * rate)
    }

    /// Real bytes-per-second learned from the sample; nil until a sampled video has a size.
    private func measuredRate(for format: DownloadFormat) -> Double? {
        var bytes: Int64 = 0
        var seconds: Double = 0
        for result in sampleResults.values {
            guard let size = result.approxDownloadSize(for: format),
                  let duration = result.durationSeconds, duration > 0 else { continue }
            bytes += size
            seconds += duration
        }
        guard seconds > 0 else { return nil }
        return Double(bytes) / seconds
    }

    /// Typical download rates (bytes/second) per quality: avc1+m4a for video, VBR-0 for MP3.
    static func nominalRate(for format: DownloadFormat) -> Double {
        switch format {
        case .video(let height):
            switch height {
            case ...399: return 80_000
            case ...599: return 115_000
            case ...799: return 200_000
            default: return 350_000
            }
        case .audioMP3:
            return 30_000
        }
    }
}
