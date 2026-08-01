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
        estimatedTotalBytes(for: format, selectedEntries: playlist.entries)
    }

    /// Estimate for a caller-selected subset. The supplied order is irrelevant to the
    /// arithmetic but deliberately remains an array: playlist URLs are not guaranteed to be
    /// unique, so a URL set cannot faithfully represent entry selection.
    ///
    /// An empty selection has a known zero-byte total. For entries whose flat playlist probe
    /// omitted a duration, known durations from the selection (or, as a fallback, the whole
    /// playlist) provide an average rather than making the estimate disappear.
    public func estimatedTotalBytes(
        for format: DownloadFormat,
        selectedEntries: [PlaylistEntry]
    ) -> Int64? {
        guard !selectedEntries.isEmpty else { return 0 }

        let durations = selectedEntries.compactMap { Self.usableDuration($0.durationSeconds) }
        let rate = measuredRate(for: format, selectedEntries: selectedEntries)
            ?? Self.nominalRate(for: format)
        if durations.isEmpty {
            // A selected entry may lack a duration even when neighboring playlist entries have
            // one. Their average is a better instant estimate than hiding the total entirely.
            let playlistDurations = playlist.entries.compactMap {
                Self.usableDuration($0.durationSeconds)
            }
            if !playlistDurations.isEmpty {
                let average = playlistDurations.reduce(0, +) / Double(playlistDurations.count)
                return Int64(average * Double(selectedEntries.count) * rate)
            }

            // No durations anywhere (rare outside YouTube): extrapolate sampled per-video size.
            let selectedSizes = selectedEntries.compactMap {
                sampleResults[$0.url]?.approxDownloadSize(for: format)
            }
            let sizes = selectedSizes.isEmpty
                ? sampleResults.values.compactMap { $0.approxDownloadSize(for: format) }
                : selectedSizes
            guard !sizes.isEmpty else { return nil }
            let average = sizes.reduce(0, +) / Int64(sizes.count)
            return average * Int64(selectedEntries.count)
        }
        // Entries without a duration count as an average-length video.
        let known = durations.reduce(0, +)
        let average = known / Double(durations.count)
        let total = known + average * Double(selectedEntries.count - durations.count)
        return Int64(total * rate)
    }

    /// Zero, negative and non-finite values are malformed metadata, not real durations. In
    /// particular, allowing infinity into the arithmetic can trap when the estimate becomes
    /// an `Int64`.
    private static func usableDuration(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Real bytes-per-second learned from the selected sample. If none of the selected entries
    /// was sampled, the playlist-wide sample remains useful as a calibration fallback.
    private func measuredRate(
        for format: DownloadFormat,
        selectedEntries: [PlaylistEntry]
    ) -> Double? {
        let selectedURLs = Set(selectedEntries.map(\.url))
        let selectedResults = sampleResults.compactMap { url, result in
            selectedURLs.contains(url) ? result : nil
        }
        return measuredRate(for: format, results: selectedResults)
            ?? measuredRate(for: format, results: Array(sampleResults.values))
    }

    private func measuredRate(for format: DownloadFormat, results: [ProbeResult]) -> Double? {
        var bytes: Int64 = 0
        var seconds: Double = 0
        for result in results {
            guard let size = result.approxDownloadSize(for: format),
                  let duration = result.durationSeconds,
                  duration.isFinite, duration > 0 else { continue }
            bytes += size
            seconds += duration
        }
        guard seconds > 0 else { return nil }
        return Double(bytes) / seconds
    }

    /// Typical download rates (bytes/second) per output profile; real samples replace them.
    static func nominalRate(for format: DownloadFormat) -> Double {
        switch format {
        case .maximumVideo:
            // A playlist may mix 1080p, 4K and 8K. Sampling replaces this conservative
            // 4K baseline as soon as yt-dlp exposes real sizes for an entry.
            return 1_500_000
        case .video(let height):
            switch height {
            case ...399: return 80_000
            case ...599: return 115_000
            case ...799: return 200_000
            case ...1199: return 350_000
            case ...1599: return 750_000
            case ...2199: return 1_500_000
            default: return 3_000_000
            }
        case .audioMP3:
            return 30_000
        case .audioM4A:
            return 24_000
        case .audioOpus:
            return 20_000
        }
    }
}
