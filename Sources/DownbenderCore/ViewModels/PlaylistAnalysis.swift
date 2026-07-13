import Foundation
import Observation

/// Live model behind the playlist panel: created the moment the user asks for a playlist,
/// BEFORE anything is probed, so the sheet opens instantly and fills in as analysis lands.
@MainActor @Observable
public final class PlaylistAnalysis {
    public let url: String
    /// nil while the flat probe is still resolving the entry list.
    public internal(set) var playlist: PlaylistProbe?
    public internal(set) var failure: String?
    /// Per-entry full probes, keyed by entry URL; fills in progressively in the background.
    public internal(set) var results: [String: ProbeResult] = [:]
    /// Entries whose background probe finished (with or without a usable size).
    public internal(set) var analyzedCount = 0

    public init(url: String) {
        self.url = url
    }

    /// Running total of the known per-video estimates for a format; nil until any video has one.
    public func estimatedTotalBytes(for format: DownloadFormat) -> (bytes: Int64, sizedVideos: Int)? {
        var total: Int64 = 0
        var sized = 0
        for result in results.values {
            if let bytes = result.approxDownloadSize(for: format) {
                total += bytes
                sized += 1
            }
        }
        return sized > 0 ? (total, sized) : nil
    }
}
