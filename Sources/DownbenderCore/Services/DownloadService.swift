import Foundation

public enum DownloadError: Error, Equatable {
    case ytdlpFailed(String)
    case stalled
}

extension DownloadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .ytdlpFailed(let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "yt-dlp failed with no error message." : trimmed
        case .stalled:
            return "The download stalled — no data arrived for a while."
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
        stallTimeout: Duration = .seconds(120),
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
        let monitor = ActivityMonitor()
        let result = try await withThrowingTaskGroup(of: ProcessResult?.self) { group in
            group.addTask { [runner, ytdlpURL] in
                try await runner.run(executableURL: ytdlpURL, arguments: args) { line in
                    monitor.touch()
                    if let p = ProgressParser.parse(line: line) {
                        monitor.arm()
                        onProgress(tracker.unified(p))
                    } else if line.contains(Self.destinationMarker) {
                        monitor.arm()
                        tracker.beginPhase()
                    }
                    // Coupled to yt-dlp's literal log text; if it changes, only the "Merging…" state is lost.
                    else if line.contains("[Merger]") || line.contains("Merging formats") {
                        monitor.disarm()
                        onMerging()
                    } else if line.hasPrefix(Self.deliveredPathPrefix) {
                        deliveredPath.append(String(line.dropFirst(Self.deliveredPathPrefix.count)))
                    }
                }
            }
            group.addTask {
                let tick = min(stallTimeout / 4, .seconds(5))
                while true {
                    try await Task.sleep(for: tick)
                    if monitor.isStalled(after: stallTimeout) { return nil }
                }
            }
            defer { group.cancelAll() }
            // First child to finish wins: the runner returns a result, the watchdog returns nil.
            guard let result = try await group.next()! else { throw DownloadError.stalled }
            return result
        }
        guard result.exitCode == 0 else { throw DownloadError.ytdlpFailed(result.stderr) }
        let path = deliveredPath.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }
}

/// Tracks stdout liveness for the stall watchdog. Armed only during download phases —
/// merge/postprocessing is local CPU work that may be legitimately silent.
final class ActivityMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var lastActivity = ContinuousClock.now
    private var armed = false

    func touch() { lock.lock(); lastActivity = .now; lock.unlock() }
    func arm() { lock.lock(); armed = true; lastActivity = .now; lock.unlock() }
    func disarm() { lock.lock(); armed = false; lock.unlock() }
    func isStalled(after timeout: Duration) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return armed && ContinuousClock.now - lastActivity > timeout
    }
}
