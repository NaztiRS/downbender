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
    /// Frozen when the user confirms a media download. Retries and relaunches must reuse it
    /// so yt-dlp can find the same partial files even if the preference later changes.
    public var fileNameTemplate: String
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
    /// Engine that actually handled the most recent probe or media-download attempt.
    /// This is informational; ordinary future retries use the then-selected global channel.
    public var lastEngineChannel: YtdlpEngineChannel?
    /// Version snapshot for the same attempt. It can be unknown until a detailed retry asks
    /// the engine to identify itself.
    public var lastEngineVersion: String?
    /// Privacy-safe, bounded details for the most recent failed operation.
    public var failureDiagnostics: FailureDiagnostics?
    /// One-shot channel requested by an explicit recovery action. It is consumed when the
    /// next probe/download starts so waiting in the queue cannot change the promised engine.
    @ObservationIgnored var nextEngineChannel: YtdlpEngineChannel?
    /// One-shot request for verbose yt-dlp logging on the next complete operation.
    @ObservationIgnored var nextAttemptCapturesDiagnostics = false

    public var source: Source = .media
    /// URLSession resume data captured when a direct download is paused/interrupted;
    /// persisted so a relaunch can continue where it left off.
    public var resumeData: Data?
    /// True while a direct download's server never declared a total size (indeterminate bar).
    public var indeterminateProgress: Bool = false

    public init(
        url: String,
        title: String,
        thumbnailURL: URL? = nil,
        format: DownloadFormat? = nil,
        fileNameTemplate: String = FileNameTemplate.defaultValue,
        destination: URL,
        state: State = .queued
    ) {
        self.url = url
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.format = format
        self.fileNameTemplate = FileNameTemplate.normalized(fileNameTemplate)
            ?? FileNameTemplate.defaultValue
        self.destination = destination
        self.state = state
    }
}
