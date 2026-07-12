import Foundation

public struct ProbeResult: Equatable, Sendable {
    public let videoID: String
    public let title: String
    public let thumbnailURL: URL?
    public let durationSeconds: Double?
    public let availableFormats: [DownloadFormat]
    public let approxSizeBytes: [DownloadFormat: Int64]
    public let subtitleLanguages: [String]

    public init(videoID: String, title: String, thumbnailURL: URL?, durationSeconds: Double?, availableFormats: [DownloadFormat], approxSizeBytes: [DownloadFormat: Int64] = [:], subtitleLanguages: [String] = []) {
        self.videoID = videoID
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.durationSeconds = durationSeconds
        self.availableFormats = availableFormats
        self.approxSizeBytes = approxSizeBytes
        self.subtitleLanguages = subtitleLanguages
    }
}

extension ProbeResult: Identifiable {
    public var id: String { videoID }
}
