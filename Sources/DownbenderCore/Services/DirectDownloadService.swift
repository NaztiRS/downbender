import Foundation

public enum DirectDownloadError: Error, Equatable, LocalizedError {
    case badStatus(Int)
    case accessDenied
    case insecureScheme
    case tooManyRedirects
    case fileTooLarge(Int64)
    case notEnoughDiskSpace
    case invalidURL

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "The server returned HTTP \(code)."
        case .accessDenied: return "Access denied — this link needs a sign-in Downbender can't provide."
        case .insecureScheme: return "This link isn't encrypted (http)."
        case .tooManyRedirects: return "The link redirected too many times."
        case .fileTooLarge(let bytes): return "The file is larger than the \(bytes.formatted(.byteCount(style: .file))) limit."
        case .notEnoughDiskSpace: return "Not enough free space to download this file."
        case .invalidURL: return "That doesn't look like a valid link."
        }
    }
}

/// Native URLSession file downloader — the non-yt-dlp engine. Mirrors UpdaterService's
/// download/replaceItemAt pattern and adds the safety yt-dlp handled for free (see the spec §3).
public struct DirectDownloadService: Sendable {
    let allowInsecureHTTP: Bool
    public init(allowInsecureHTTP: Bool = false) { self.allowInsecureHTTP = allowInsecureHTTP }

    public static func makeSession(configuration: URLSessionConfiguration = .default) -> URLSession {
        URLSession(configuration: configuration)
    }

    @discardableResult
    public func download(
        url: String,
        destination: URL,
        tmpDirectory: URL,
        suggestedName: String? = nil,
        maxBytes: Int64? = nil,
        session: URLSession = makeSession(),
        onProgress: @Sendable @escaping (DownloadProgress) -> Void
    ) async throws -> URL {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw DirectDownloadError.invalidURL
        }
        let delegate = DirectProgressDelegate(onProgress: onProgress)
        let (tmpURL, response) = try await session.download(from: parsed, delegate: delegate)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        if status == 401 || status == 403 { throw DirectDownloadError.accessDenied }
        guard (200...299).contains(status) else { throw DirectDownloadError.badStatus(status) }

        let name = Self.deliveredName(suggestedName: suggestedName, response: response, requestURL: parsed)
        let finalURL = destination.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: tmpURL)
        return finalURL
    }

    /// v1 name derivation (traversal-safe sanitization arrives in Task 5).
    static func deliveredName(suggestedName: String?, response: URLResponse, requestURL: URL) -> String {
        if let suggestedName, !suggestedName.isEmpty { return suggestedName }
        let last = requestURL.lastPathComponent
        if !last.isEmpty, last != "/" { return last }
        return response.suggestedFilename ?? "download"
    }
}

/// Translates URLSession byte callbacks into a DownloadProgress. Speed/ETA are derived from
/// deltas (URLSession supplies neither); an unknown total yields an indeterminate fraction.
final class DirectProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (DownloadProgress) -> Void
    init(onProgress: @escaping @Sendable (DownloadProgress) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        onProgress(DownloadProgress(fraction: fraction, speedText: "", etaText: "",
                                    downloadedBytes: totalBytesWritten,
                                    totalBytes: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
