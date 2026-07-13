import Foundation

public struct PlaylistEntry: Equatable, Sendable {
    public let url: String
    public let title: String
    public let thumbnailURL: URL?

    public init(url: String, title: String, thumbnailURL: URL? = nil) {
        self.url = url
        self.title = title
        self.thumbnailURL = thumbnailURL
    }
}

public struct PlaylistProbe: Equatable, Sendable {
    public let title: String
    public let entries: [PlaylistEntry]

    public init(title: String, entries: [PlaylistEntry]) {
        self.title = title
        self.entries = entries
    }
}

/// A probed URL is either a single video or a playlist; the UI flow forks on this.
public enum ProbeOutcome: Equatable, Sendable {
    case video(ProbeResult)
    case playlist(PlaylistProbe)

    public var videoResult: ProbeResult? {
        guard case .video(let result) = self else { return nil }
        return result
    }
}
