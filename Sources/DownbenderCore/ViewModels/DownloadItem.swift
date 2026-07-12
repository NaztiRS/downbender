import Foundation
import Observation

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

    public let id = UUID()
    public let url: String
    public var title: String
    public var thumbnailURL: URL?
    public var format: DownloadFormat?
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
