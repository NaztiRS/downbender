import CryptoKit
import Foundation

public enum UpdaterError: Error, Equatable, LocalizedError {
    case badStatus(Int)
    case badVersionOutput
    case checksumNotFound(String)
    case checksumMismatch(expected: String, actual: String)
    case versionMismatch(expected: String, actual: String)
    case validationTimedOut
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
        case .versionMismatch:
            return "The downloaded yt-dlp file reported an unexpected version."
        case .validationTimedOut:
            return "The downloaded yt-dlp file took too long to validate."
        case .ytdlpFailed(let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "yt-dlp failed while checking its version." : trimmed
        }
    }
}

public struct NightlyInstallResult: Sendable, Equatable {
    public let binaryURL: URL
    public let version: String

    public init(binaryURL: URL, version: String) {
        self.binaryURL = binaryURL
        self.version = version
    }
}

public struct UpdaterService: Sendable {
    public let appSupportDirectory: URL
    public static let latestYtdlpURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
    public static let latestYtdlpChecksumsURL = URL(
        string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS"
    )!
    public static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
    public static let latestNightlyReleaseAPIURL = URL(
        string: "https://api.github.com/repos/yt-dlp/yt-dlp-nightly-builds/releases/latest"
    )!

    public init(appSupportDirectory: URL) {
        self.appSupportDirectory = appSupportDirectory
    }

    /// Runs yt-dlp without loading user configuration; output is one version line.
    public func installedVersion(
        runner: ProcessRunning,
        ytdlpURL: URL,
        timeout: Duration = .seconds(30)
    ) async throws -> String {
        do {
            return try await withTotalTimeout(timeout) {
                let acc = Accumulator()
                let result = try await runner.run(
                    executableURL: ytdlpURL,
                    arguments: ["--ignore-config", "--version"],
                    onStdoutLine: { acc.append($0) }
                )
                try Task.checkCancellation()
                guard result.exitCode == 0 else { throw UpdaterError.ytdlpFailed(result.stderr) }
                let version = acc.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !version.isEmpty else { throw UpdaterError.badVersionOutput }
                return version
            }
        } catch is TimedOutError {
            throw UpdaterError.validationTimedOut
        }
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

    /// Installs the latest official nightly without ever modifying the stable engine. The API
    /// tag pins both asset requests to the same release, avoiding a split-brain `latest` update.
    /// The downloaded candidate is checksummed, made executable, and asked for its exact version
    /// before an atomic swap makes it visible to the rest of the app.
    public func installLatestNightly(
        session: URLSession = .shared,
        runner: ProcessRunning,
        latestReleaseURL: URL = latestNightlyReleaseAPIURL,
        onProgress: @escaping @Sendable (Double?) -> Void = { _ in }
    ) async throws -> NightlyInstallResult {
        let version = try await Self.latestVersion(session: session, from: latestReleaseURL)
        let assets = try Self.nightlyAssetURLs(for: version)

        let (sumsData, sumsResponse) = try await session.data(from: assets.checksums)
        guard (sumsResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdaterError.badStatus((sumsResponse as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let sums = String(data: sumsData, encoding: .utf8),
              let expectedChecksum = Self.parseSHA256Sums(sums, file: assets.binary.lastPathComponent)
        else {
            throw UpdaterError.checksumNotFound(assets.binary.lastPathComponent)
        }

        let delegate = DownloadProgressDelegate(onProgress: onProgress)
        let (downloaded, binaryResponse) = try await session.download(from: assets.binary, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard (binaryResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdaterError.badStatus((binaryResponse as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        let candidate = appSupportDirectory.appendingPathComponent(
            ".yt-dlp-nightly-\(UUID().uuidString).candidate"
        )
        defer { try? fileManager.removeItem(at: candidate) }
        try fileManager.copyItem(at: downloaded, to: candidate)

        let actualChecksum = try Self.sha256Hex(of: candidate)
        guard actualChecksum == expectedChecksum else {
            throw UpdaterError.checksumMismatch(expected: expectedChecksum, actual: actualChecksum)
        }

        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: candidate.path)
        let actualVersion: String
        do {
            actualVersion = try await withTotalTimeout(.seconds(30)) {
                let output = Accumulator()
                let result = try await runner.run(
                    executableURL: candidate,
                    arguments: ["--ignore-config", "--version"],
                    onStdoutLine: { output.append($0) }
                )
                guard result.exitCode == 0 else { throw UpdaterError.ytdlpFailed(result.stderr) }
                let reported = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !reported.isEmpty else { throw UpdaterError.badVersionOutput }
                return reported
            }
        } catch is TimedOutError {
            throw UpdaterError.validationTimedOut
        }
        guard actualVersion == version else {
            throw UpdaterError.versionMismatch(expected: version, actual: actualVersion)
        }

        let destination = appSupportDirectory.appendingPathComponent("yt-dlp-nightly_macos")
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: candidate,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try fileManager.moveItem(at: candidate, to: destination)
        }
        return NightlyInstallResult(binaryURL: destination, version: version)
    }

    static func nightlyAssetURLs(for tag: String) throws -> (binary: URL, checksums: URL) {
        guard !tag.isEmpty, tag.utf8.allSatisfy(Self.isSafeReleaseTagByte) else {
            throw UpdaterError.badVersionOutput
        }
        let base = "https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/download/\(tag)"
        guard let binary = URL(string: "\(base)/yt-dlp_macos"),
              let checksums = URL(string: "\(base)/SHA2-256SUMS")
        else {
            throw UpdaterError.badVersionOutput
        }
        return (binary, checksums)
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

    private static func isSafeReleaseTagByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 45...46, 48...57, 65...90, 95, 97...122:
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
