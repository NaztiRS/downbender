public enum DownloadProgressStatus: Equatable, Sendable {
    case unknown
    case downloading
    case finished
}

public struct DownloadProgress: Equatable, Sendable {
    public let fraction: Double
    public let speedText: String
    public let etaText: String
    /// Bytes of the CURRENT file (yt-dlp emits "NA" → nil); feed the unified multi-phase progress.
    public let downloadedBytes: Int64?
    public let totalBytes: Int64?
    /// `yt-dlp` can report 100% while a fragmented download is still discovering its size.
    public let status: DownloadProgressStatus
    public let fragmentIndex: Int?
    public let fragmentCount: Int?

    public init(
        fraction: Double,
        speedText: String,
        etaText: String,
        downloadedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        status: DownloadProgressStatus = .unknown,
        fragmentIndex: Int? = nil,
        fragmentCount: Int? = nil
    ) {
        self.fraction = fraction
        self.speedText = speedText
        self.etaText = etaText
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.status = status
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
    }
}
