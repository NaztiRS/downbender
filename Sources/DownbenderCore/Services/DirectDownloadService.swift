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
    public init() {}

    public static func makeSession(configuration: URLSessionConfiguration = .default) -> URLSession {
        URLSession(configuration: configuration)
    }

    /// A HEAD content-type that indicates a downloadable file rather than a web page. Used by the
    /// probe-failure fallback so a transient yt-dlp error on a real page isn't mistaken for a file.
    public static func isDownloadableContentType(_ type: String?) -> Bool {
        guard let type = type?.lowercased() else { return false }
        return !type.hasPrefix("text/html") && !type.hasPrefix("application/xhtml")
    }

    @discardableResult
    public func download(
        url: String,
        destination: URL,
        tmpDirectory: URL,
        suggestedName: String? = nil,
        maxBytes: Int64? = nil,
        allowInsecureHTTP: Bool = false,
        resumeData: Data? = nil,
        session: URLSession = makeSession(),
        onProgress: @Sendable @escaping (DownloadProgress) -> Void,
        onResumeData: (@Sendable (Data) -> Void)? = nil
    ) async throws -> URL {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw DirectDownloadError.invalidURL
        }
        let scheme = parsed.scheme?.lowercased()
        if scheme == "http", !allowInsecureHTTP { throw DirectDownloadError.insecureScheme }
        guard scheme == "https" || scheme == "http" else { throw DirectDownloadError.invalidURL }

        // Resume data must be a property-list DICTIONARY (URLSession's format); anything else
        // raises an ObjC exception inside downloadTask(withResumeData:) — even a bare string
        // parses as a legacy plist — so validate the shape and fall back to a fresh download.
        let usableResumeData = resumeData.flatMap { data in
            ((try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]) != nil
                ? data : nil
        }
        let (tmpURL, response): (URL, URLResponse)
        if let usableResumeData {
            do {
                (tmpURL, response) = try await Self.perform(
                    task: session.downloadTask(withResumeData: usableResumeData),
                    tmpDirectory: tmpDirectory, onProgress: onProgress, onResumeData: onResumeData
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Stale or server-rejected resume data: restart from scratch instead of failing.
                (tmpURL, response) = try await Self.perform(
                    task: session.downloadTask(with: parsed),
                    tmpDirectory: tmpDirectory, onProgress: onProgress, onResumeData: onResumeData
                )
            }
        } else {
            (tmpURL, response) = try await Self.perform(
                task: session.downloadTask(with: parsed),
                tmpDirectory: tmpDirectory, onProgress: onProgress, onResumeData: onResumeData
            )
        }
        // Never leak the body: every early throw below leaves the temp file cleaned up.
        var delivered = false
        defer { if !delivered { try? FileManager.default.removeItem(at: tmpURL) } }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        if status == 401 || status == 403 { throw DirectDownloadError.accessDenied }
        guard (200...299).contains(status) else { throw DirectDownloadError.badStatus(status) }

        if let maxBytes {
            let observed = Int64((try? tmpURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            let expected = http?.expectedContentLength ?? -1
            let effective = observed > 0 ? observed : max(expected, 0)
            if effective > maxBytes { throw DirectDownloadError.fileTooLarge(maxBytes) }
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let name = Self.safeFileName(suggestedName ?? Self.contentDispositionFilename(response) ?? parsed.lastPathComponent)
        let candidate = destination.appendingPathComponent(name)
        // Defense in depth: even after sanitization, confirm the resolved path stays inside destination.
        guard candidate.standardizedFileURL.path.hasPrefix(destination.standardizedFileURL.path + "/") else {
            throw DirectDownloadError.invalidURL
        }
        let finalURL = Self.deDuplicated(candidate)
        _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: tmpURL)
        delivered = true
        Self.markQuarantined(finalURL)
        return finalURL
    }

    static func perform(
        task: URLSessionDownloadTask,
        tmpDirectory: URL,
        onProgress: @Sendable @escaping (DownloadProgress) -> Void,
        onResumeData: (@Sendable (Data) -> Void)?
    ) async throws -> (URL, URLResponse) {
        let executor = DirectDownloadExecutor(tmpDirectory: tmpDirectory, onProgress: onProgress, onResumeData: onResumeData)
        task.delegate = executor
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                executor.begin(continuation: continuation, task: task)
            }
        } onCancel: {
            // Resume data (when the server supports ranges) lands via didCompleteWithError's userInfo.
            task.cancel(byProducingResumeData: { _ in })
        }
    }

    /// Issues a HEAD to learn size/name/type BEFORE downloading (drives the mini-confirmation).
    /// Never throws on a missing Content-Length — an unknown size is a valid, expected answer.
    public func headInfo(url: String, session: URLSession = makeSession()) async throws -> DirectFileInfo {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw DirectDownloadError.invalidURL
        }
        var request = URLRequest(url: parsed)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        if status == 401 || status == 403 { throw DirectDownloadError.accessDenied }
        let size = http?.expectedContentLength ?? -1
        let name = Self.contentDispositionFilename(response).map { Self.safeFileName($0) }
            ?? Self.safeFileName(parsed.lastPathComponent)
        return DirectFileInfo(
            suggestedName: name,
            sizeBytes: size > 0 ? size : nil,
            contentType: http?.value(forHTTPHeaderField: "Content-Type")
        )
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

    /// Marks the file so Gatekeeper/XProtect evaluates it on first open — the same protection a
    /// browser download gets. Best-effort: a failure to set the xattr must not fail the download.
    static func markQuarantined(_ url: URL) {
        let value = "0181;00000000;Downbender;\(UUID().uuidString)"
        _ = value.withCString { setxattr(url.path, "com.apple.quarantine", $0, value.utf8.count, 0, 0) }
    }

    static func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }
}

/// Delegate bridge for a manually-driven URLSessionDownloadTask. The async
/// `session.download(from:)` API can neither produce resume data on cancel nor choose where
/// the temp file lives; driving the task by hand fixes both. The finished file is moved into
/// tmpDirectory synchronously inside the callback (the system location dies on return).
final class DirectDownloadExecutor: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let tmpDirectory: URL
    private let onProgress: @Sendable (DownloadProgress) -> Void
    private let onResumeData: (@Sendable (Data) -> Void)?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var movedURL: URL?

    init(
        tmpDirectory: URL,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void,
        onResumeData: (@Sendable (Data) -> Void)?
    ) {
        self.tmpDirectory = tmpDirectory
        self.onProgress = onProgress
        self.onResumeData = onResumeData
    }

    func begin(continuation: CheckedContinuation<(URL, URLResponse), Error>, task: URLSessionDownloadTask) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
        task.resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let known = totalBytesExpectedToWrite > 0
        // Unknown total → totalBytes nil, NOT a frozen 0%: the UI shows an indeterminate bar.
        onProgress(DownloadProgress(
            fraction: known ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0,
            speedText: "", etaText: "",
            downloadedBytes: totalBytesWritten,
            totalBytes: known ? totalBytesExpectedToWrite : nil
        ))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        try? FileManager.default.createDirectory(at: tmpDirectory, withIntermediateDirectories: true)
        let moved = tmpDirectory.appendingPathComponent("direct-\(UUID().uuidString).tmp")
        do {
            try FileManager.default.moveItem(at: location, to: moved)
            lock.lock()
            movedURL = moved
            lock.unlock()
        } catch {
            // movedURL stays nil → didCompleteWithError reports the failure.
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let moved = movedURL
        lock.unlock()
        if let error {
            if let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                onResumeData?(resume)
            }
            if (error as? URLError)?.code == .cancelled {
                continuation?.resume(throwing: CancellationError())
            } else {
                continuation?.resume(throwing: error)
            }
        } else if let moved, let response = task.response {
            continuation?.resume(returning: (moved, response))
        } else {
            continuation?.resume(throwing: URLError(.cannotWriteToFile))
        }
    }
}
