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
