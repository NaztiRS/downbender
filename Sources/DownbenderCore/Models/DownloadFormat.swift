public enum DownloadFormat: Hashable, Identifiable, Sendable {
    case video(height: Int)
    case audioMP3

    public var id: String {
        switch self {
        case .video(let h): return "v\(h)"
        case .audioMP3: return "mp3"
        }
    }

    public var label: String {
        switch self {
        case .video(let h): return "\(h)p"
        case .audioMP3: return "Extract MP3"
        }
    }
}

public extension DownloadFormat {
    /// Inverse of `id` ("v1080" / "mp3"); used by queue persistence.
    init?(id: String) {
        if id == "mp3" {
            self = .audioMP3
        } else if id.hasPrefix("v"), let height = Int(id.dropFirst()) {
            self = .video(height: height)
        } else {
            return nil
        }
    }
}
