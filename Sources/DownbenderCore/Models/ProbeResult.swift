import Foundation

public struct ProbeResult: Equatable, Sendable {
    public let videoID: String
    public let title: String
    public let thumbnailURL: URL?
    public let durationSeconds: Double?
    public let availableFormats: [DownloadFormat]
    public let approxSizeBytes: [DownloadFormat: Int64]
    public let subtitleLanguages: [String]
    public let extractor: String?

    public init(videoID: String, title: String, thumbnailURL: URL?, durationSeconds: Double?, availableFormats: [DownloadFormat], approxSizeBytes: [DownloadFormat: Int64] = [:], subtitleLanguages: [String] = [], extractor: String? = nil) {
        self.videoID = videoID
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.durationSeconds = durationSeconds
        self.availableFormats = availableFormats
        self.approxSizeBytes = approxSizeBytes
        self.subtitleLanguages = subtitleLanguages
        self.extractor = extractor
    }
}

public extension ProbeResult {
    /// yt-dlp matched only via the generic extractor: treat the result as ambiguous rather than
    /// as confirmed media (the generic extractor matches almost any URL).
    var isGeneric: Bool { extractor == "generic" }
}

extension ProbeResult: Identifiable {
    public var id: String { videoID }
}

public extension ProbeResult {
    /// What downloading this video at `format` would roughly weigh: mirrors the selector's
    /// `height<=H` fallback by sizing the best listed quality at or below the request.
    /// Never invents — nil when that quality carries no size (and always for MP3).
    func approxDownloadSize(for format: DownloadFormat) -> Int64? {
        switch format {
        case .audioMP3:
            return nil
        case .maximumVideo:
            let highest = availableFormats.compactMap { fmt -> Int? in
                guard case .video(let h) = fmt else { return nil }
                return h
            }.max()
            guard let highest else { return nil }
            // Maximum is downloaded with the original-codec MKV profile. The stored estimate
            // for a <=1080p row describes the compatibility MP4 profile, so it is not reusable.
            guard highest > 1080 else { return nil }
            return approxSizeBytes[.video(height: highest)]
        case .video(let requested):
            let heights = availableFormats.compactMap { fmt -> Int? in
                guard case .video(let h) = fmt, h <= requested else { return nil }
                return h
            }
            guard let best = heights.max() else { return nil }
            // A high ceiling keeps the MKV profile even when it falls back below 1440p.
            guard requested <= 1080 || best > 1080 else { return nil }
            return approxSizeBytes[.video(height: best)]
        }
    }
}

public extension ProbeResult {
    /// The listed format closest to `preferred`, mirroring the download selector's `height<=H`
    /// fallback: exact or tallest below the request. A ceiling is never exceeded; nil asks
    /// the caller to show the panel when every available video is taller than the preference.
    /// MP3 is returned only when it is the sole kind of offer.
    func closestMatch(to preferred: DownloadFormat) -> DownloadFormat? {
        switch preferred {
        case .audioMP3:
            return .audioMP3
        case .maximumVideo:
            let highest = availableFormats.compactMap { fmt -> Int? in
                guard case .video(let h) = fmt else { return nil }
                return h
            }.max()
            if let highest { return .video(height: highest) }
            return availableFormats.contains(.audioMP3) ? .audioMP3 : nil
        case .video(let requested):
            let heights = availableFormats.compactMap { fmt -> Int? in
                guard case .video(let h) = fmt else { return nil }
                return h
            }
            if heights.isEmpty {
                return availableFormats.contains(.audioMP3) ? .audioMP3 : nil
            }
            let below = heights.filter { $0 <= requested }
            return below.max().map { .video(height: $0) }
        }
    }
}
