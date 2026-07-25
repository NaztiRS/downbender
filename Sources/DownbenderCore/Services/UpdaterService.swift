import CryptoKit
import Foundation

public enum UpdaterError: Error, Equatable, LocalizedError {
    case badStatus(Int)
    case badVersionOutput
    case checksumNotFound(String)
    case checksumMismatch(expected: String, actual: String)
    case ytdlpFailed(String)

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code):
            return "GitHub returned HTTP \(code)."
        case .badVersionOutput:
            return "Couldn't read the yt-dlp version."
        case .checksumNotFound(let file):
            return "The official checksum list doesn't contain \(file)."
        case .checksumMismatch:
            return "The downloaded yt-dlp file failed its integrity check."
        case .ytdlpFailed(let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "yt-dlp failed while checking its version." : trimmed
        }
    }
}

public struct UpdaterService: Sendable {
    public let appSupportDirectory: URL
    public static let latestYtdlpURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
    public static let latestYtdlpChecksumsURL = URL(
        string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS"
    )!
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

    /// Downloads the latest yt-dlp_macos, verifies it against the release's SHA-256 list,
    /// then installs it in Application Support and marks it executable.
    @discardableResult
    public func updateYtdlp(
        session: URLSession = .shared,
        binaryURL: URL = latestYtdlpURL,
        checksumsURL: URL = latestYtdlpChecksumsURL,
        onProgress: @escaping @Sendable (Double?) -> Void = { _ in }
    ) async throws -> URL {
        let (sumsData, sumsResponse) = try await session.data(from: checksumsURL)
        guard (sumsResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdaterError.badStatus((sumsResponse as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let filename = binaryURL.lastPathComponent
        guard let sums = String(data: sumsData, encoding: .utf8),
              let expectedChecksum = Self.parseSHA256Sums(sums, file: filename)
        else {
            throw UpdaterError.checksumNotFound(filename)
        }

        try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        let delegate = DownloadProgressDelegate(onProgress: onProgress)
        let (tmp, response) = try await session.download(from: binaryURL, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UpdaterError.badStatus(code)
        }

        let actualChecksum = try Self.sha256Hex(of: tmp)
        guard actualChecksum == expectedChecksum else {
            throw UpdaterError.checksumMismatch(expected: expectedChecksum, actual: actualChecksum)
        }

        // Prepare the verified file completely before touching the installed copy. Asking
        // replaceItemAt to use the new metadata keeps this executable mode after the swap.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        let dest = appSupportDirectory.appendingPathComponent("yt-dlp_macos")
        if FileManager.default.fileExists(atPath: dest.path) {
            // replaceItemAt is atomic: no half-deleted binary if interrupted mid-swap.
            _ = try FileManager.default.replaceItemAt(
                dest,
                withItemAt: tmp,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try FileManager.default.moveItem(at: tmp, to: dest)
        }
        return dest
    }

    static func parseSHA256Sums(_ contents: String, file: String) -> String? {
        for line in contents.split(whereSeparator: \.isNewline) {
            let fields = line.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 2 else { continue }

            let checksum = String(fields[0])
            var filename = String(fields[1]).trimmingCharacters(in: .whitespaces)
            // Coreutils uses a leading "*" to mark binary-mode entries.
            if filename.first == "*" {
                filename.removeFirst()
            }
            guard filename == file,
                  checksum.utf8.count == 64,
                  checksum.utf8.allSatisfy(Self.isASCIIHexDigit)
            else { continue }
            return checksum.lowercased()
        }
        return nil
    }

    static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isASCIIHexDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...70, 97...102:
            return true
        default:
            return false
        }
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
