import Foundation
import Observation

public struct DirectFileInfo: Equatable, Sendable {
    public var suggestedName: String?
    public var sizeBytes: Int64?
    public var contentType: String?
    public init(suggestedName: String? = nil, sizeBytes: Int64? = nil, contentType: String? = nil) {
        self.suggestedName = suggestedName
        self.sizeBytes = sizeBytes
        self.contentType = contentType
    }
}

@MainActor @Observable
public final class DownloadItem: Identifiable {
    public enum State: Equatable {
        case probing
        case probeFailed(String)
        case readyToChoose
        case queued, downloading, merging, done
        /// Process terminated at the user's request; resumable (yt-dlp continues the .part files).
        case paused
        case failed(String)
        case cancelled
    }

    /// What kind of download this item is. `.media` is the yt-dlp path (today's behavior);
    /// the others take the native URLSession engine. The UI reuses `.readyToChoose` for the
    /// direct/ambiguous confirmation, discriminating on this.
    public enum Source: Equatable, Sendable {
        case media
        case directFile(DirectFileInfo)
        case ambiguous(DirectFileInfo)
    }

    public let id = UUID()
    public let url: String
    public var title: String
    public var thumbnailURL: URL?
    public var format: DownloadFormat?
    public var includeSubtitles: Bool = false
    /// The user asked to expand this watch+list URL into its playlist; survives probe retries.
    public var expandsPlaylist: Bool = false
    public var destination: URL
    public var state: State
    public var probe: ProbeResult?
    /// Estimated total size (video+audio) of the chosen format; gives the unified progress precision.
    public var expectedTotalBytes: Int64?
    public var fraction: Double = 0
    public var speedText: String = ""
    public var etaText: String = ""
    public var deliveredNote: String = ""
    public var deliveredMismatch: Bool = false
    public var deliveredFileURL: URL?

    public var source: Source = .media
    /// Reserved for real HTTP pause/resume (fase 2); unused in v1.
    public var resumeData: Data?

    public init(
        url: String,
        title: String,
        thumbnailURL: URL? = nil,
        format: DownloadFormat? = nil,
        destination: URL,
        state: State = .queued
    ) {
        self.url = url
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.format = format
        self.destination = destination
        self.state = state
    }
}
