import Foundation

public enum UpdaterError: Error, Equatable, LocalizedError {
    case badStatus(Int)
    case badVersionOutput
    case ytdlpFailed(String)

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code):
            return "GitHub returned HTTP \(code)."
        case .badVersionOutput:
            return "Couldn't read the yt-dlp version."
        case .ytdlpFailed(let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "yt-dlp failed while checking its version." : trimmed
        }
    }
}

public struct UpdaterService: Sendable {
    public let appSupportDirectory: URL
    public static let latestYtdlpURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
    public static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!

    public init(appSupportDirectory: URL) {
        self.appSupportDirectory = appSupportDirectory
    }

    /// Runs `yt-dlp --version`; the output is a single date line, e.g. "2025.06.30".
    public func installedVersion(runner: ProcessRunning, ytdlpURL: URL) async throws -> String {
        let acc = Accumulator()
        let result = try await runner.run(
            executableURL: ytdlpURL,
            arguments: ["--version"],
            onStdoutLine: { acc.append($0) }
        )
        guard result.exitCode == 0 else { throw UpdaterError.ytdlpFailed(result.stderr) }
        let version = acc.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { throw UpdaterError.badVersionOutput }
        return version
    }

    /// Latest published version per the GitHub API (`tag_name`); serves both the engine and app checks.
    public static func latestVersion(session: URLSession = .shared, from url: URL = latestReleaseAPIURL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects (403) API requests without a User-Agent.
        request.setValue("Downbender", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdaterError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try parseTagName(data)
    }

    static func parseTagName(_ data: Data) throws -> String {
        struct Release: Decodable { let tag_name: String }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            throw UpdaterError.badVersionOutput
        }
        let tag = release.tag_name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { throw UpdaterError.badVersionOutput }
        return tag
    }

    /// yt-dlp versions are dates (2025.06.30); exact equality suffices for "up to date".
    public static func isUpToDate(installed: String, latest: String) -> Bool {
        installed.trimmingCharacters(in: .whitespacesAndNewlines)
            == latest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Downloads the latest yt-dlp_macos to Application Support and marks it executable.
    @discardableResult
    public func updateYtdlp(
        session: URLSession = .shared,
        onProgress: @escaping @Sendable (Double?) -> Void = { _ in }
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        let delegate = DownloadProgressDelegate(onProgress: onProgress)
        let (tmp, response) = try await session.download(from: Self.latestYtdlpURL, delegate: delegate)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UpdaterError.badStatus(code)
        }
        let dest = appSupportDirectory.appendingPathComponent("yt-dlp_macos")
        // replaceItemAt is atomic: no half-deleted binary if interrupted mid-swap.
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        return dest
    }
}

/// Translates `didWriteData` into a 0…1 fraction, or nil when the total is unknown (indeterminate).
final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double?) -> Void
    /// Fallback total (from a prior HEAD) used when the GET response omits its size.
    let expectedBytes: Int64?
    init(onProgress: @escaping @Sendable (Double?) -> Void, expectedBytes: Int64? = nil) {
        self.onProgress = onProgress
        self.expectedBytes = expectedBytes
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // Prefer the GET's own total; fall back to the HEAD size (GitHub assets can arrive chunked
        // behind a CDN redirect with no total). Only when neither is known do we report nil
        // (indeterminate) — never stay silent, which would freeze the bar at 0% while bytes flow.
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (expectedBytes ?? -1)
        if total > 0 {
            onProgress(min(max(Double(totalBytesWritten) / Double(total), 0), 1))
        } else {
            onProgress(nil)
        }
    }

    // Required by the protocol; the async download already returns the temporary URL.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
