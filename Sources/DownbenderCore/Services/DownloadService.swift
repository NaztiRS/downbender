import Foundation

public enum DownloadError: Error, Equatable {
    case ytdlpFailed(String)
}

extension DownloadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .ytdlpFailed(let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "yt-dlp failed with no error message." : trimmed
        }
    }
}

public struct DownloadService: Sendable {
    let runner: ProcessRunning
    let ytdlpURL: URL
    let ffmpegDirectory: URL
    let denoURL: URL?

    public init(
        runner: ProcessRunning,
        ytdlpURL: URL,
        ffmpegDirectory: URL,
        denoURL: URL? = nil
    ) {
        self.runner = runner
        self.ytdlpURL = ytdlpURL
        self.ffmpegDirectory = ffmpegDirectory
        self.denoURL = denoURL
    }

    private static let deliveredPathPrefix = "DBPATH "
    /// Emitted once per file yt-dlp starts; delimits the unified-progress phases (video → audio).
    private static let destinationMarker = "[download] Destination:"

    @discardableResult
    public func download(
        url: String,
        format: DownloadFormat,
        destination: URL,
        tmpDirectory: URL,
        useTVClient: Bool = false,
        cookiesBrowser: String? = nil,
        includeSubtitles: Bool = false,
        expectedTotalBytes: Int64? = nil,
        onProgress: @Sendable @escaping (DownloadProgress) -> Void,
        onMerging: @Sendable @escaping () -> Void = {}
    ) async throws -> URL? {
        let args = DownloadArgsBuilder.arguments(
            url: url, format: format, destination: destination,
            tmpDirectory: tmpDirectory, ffmpegDirectory: ffmpegDirectory,
            denoURL: denoURL, cookiesBrowser: cookiesBrowser,
            includeSubtitles: includeSubtitles, useTVClient: useTVClient
        )
        // bv*+ba downloads 2 files, audio-only 1; the tracker fuses the phases into one monotonic bar.
        let tracker = UnifiedProgressTracker(
            expectedTotalBytes: expectedTotalBytes,
            expectedPhases: format == .audioMP3 ? 1 : 2
        )
        let deliveredPath = Accumulator()
        let result = try await runner.run(executableURL: ytdlpURL, arguments: args) { line in
            if let p = ProgressParser.parse(line: line) { onProgress(tracker.unified(p)) }
            else if line.contains(Self.destinationMarker) { tracker.beginPhase() }
            // Coupled to yt-dlp's literal log text; if it changes, only the "Merging…" state is lost.
            else if line.contains("[Merger]") || line.contains("Merging formats") { onMerging() }
            else if line.hasPrefix(Self.deliveredPathPrefix) {
                deliveredPath.append(String(line.dropFirst(Self.deliveredPathPrefix.count)))
            }
        }
        guard result.exitCode == 0 else { throw DownloadError.ytdlpFailed(result.stderr) }
        let path = deliveredPath.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }
}
