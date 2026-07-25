public enum DownloadFormat: Hashable, Identifiable, Sendable {
    /// Highest video quality offered by each source. Primarily used by defaults and
    /// playlists, where there is no single probed height to persist ahead of time.
    case maximumVideo
    case video(height: Int)
    case audioMP3

    public var id: String {
        switch self {
        case .maximumVideo: return "vmax"
        case .video(let h): return "v\(h)"
        case .audioMP3: return "mp3"
        }
    }

    public var label: String {
        switch self {
        case .maximumVideo: return "Maximum available"
        case .video(let h):
            switch h {
            case 2160: return "2160p (4K)"
            case 4320: return "4320p (8K)"
            default: return "\(h)p"
            }
        case .audioMP3: return "Extract MP3"
        }
    }

    /// Final container promised by the download profile.
    public var containerLabel: String {
        switch self {
        case .maximumVideo: return "MKV"
        case .video(let height): return height > 1080 ? "MKV" : "MP4"
        case .audioMP3: return "MP3"
        }
    }

    /// Label for preferences that act as a ceiling rather than a probed exact choice.
    public var preferenceLabel: String {
        switch self {
        case .maximumVideo:
            return label
        case .video:
            return "Up to \(label)"
        case .audioMP3:
            return label
        }
    }
}

public extension DownloadFormat {
    /// Inverse of `id` ("vmax" / "v1080" / "mp3"); used by queue persistence.
    init?(id: String) {
        if id == "vmax" {
            self = .maximumVideo
        } else if id == "mp3" {
            self = .audioMP3
        } else if id.hasPrefix("v"), let height = Int(id.dropFirst()), height > 0 {
            self = .video(height: height)
        } else {
            return nil
        }
    }
}
