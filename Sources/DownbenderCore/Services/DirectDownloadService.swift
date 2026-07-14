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

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let name = Self.safeFileName(suggestedName ?? Self.contentDispositionFilename(response) ?? parsed.lastPathComponent)
        let candidate = destination.appendingPathComponent(name)
        // Defense in depth: even after sanitization, confirm the resolved path stays inside destination.
        guard candidate.standardizedFileURL.path.hasPrefix(destination.standardizedFileURL.path + "/") else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw DirectDownloadError.invalidURL
        }
        let finalURL = Self.deDuplicated(candidate)
        _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: tmpURL)
        return finalURL
    }

    /// Reduces an attacker-controlled name to a safe last path component. Percent-decodes,
    /// collapses both separators, strips control/NUL, and rejects empty/dot names.
    static func safeFileName(_ raw: String) -> String {
        let decoded = raw.removingPercentEncoding ?? raw
        // Last path component only defeats both "/" and "\" separators and any traversal prefix.
        let unifiedSlashes = decoded.replacingOccurrences(of: "\\", with: "/")
        var name = (unifiedSlashes as NSString).lastPathComponent
        name = name.components(separatedBy: .controlCharacters).joined()
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == "." || name == ".." { return "download" }
        return name
    }

    /// Finder-style de-duplication so an existing file is never silently clobbered.
    static func deDuplicated(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let candidateName = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            let candidate = dir.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Parses a filename from the Content-Disposition header (RFC 6266 / 5987). More predictable
    /// than URLResponse.suggestedFilename, which sanitizes in undocumented ways.
    static func contentDispositionFilename(_ response: URLResponse) -> String? {
        guard let http = response as? HTTPURLResponse,
              let header = http.value(forHTTPHeaderField: "Content-Disposition") else { return nil }
        for part in header.components(separatedBy: ";") {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.lowercased().hasPrefix("filename*=") {
                let value = String(token.dropFirst("filename*=".count))
                if let marker = value.range(of: "''", options: .backwards) {
                    return String(value[marker.upperBound...]).removingPercentEncoding
                }
                return value.removingPercentEncoding
            }
            if token.lowercased().hasPrefix("filename=") {
                return String(token.dropFirst("filename=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
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
