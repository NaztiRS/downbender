public struct DownloadProgress: Equatable, Sendable {
    public let fraction: Double
    public let speedText: String
    public let etaText: String
    /// Bytes of the CURRENT file (yt-dlp emits "NA" → nil); feed the unified multi-phase progress.
    public let downloadedBytes: Int64?
    public let totalBytes: Int64?

    public init(
        fraction: Double,
        speedText: String,
        etaText: String,
        downloadedBytes: Int64? = nil,
        totalBytes: Int64? = nil
    ) {
        self.fraction = fraction
        self.speedText = speedText
        self.etaText = etaText
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
    }
}
