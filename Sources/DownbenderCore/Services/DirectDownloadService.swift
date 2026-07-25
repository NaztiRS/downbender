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
    static let maximumRedirects = 10

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
        let parsed = try Self.validatedURL(url, allowInsecureHTTP: allowInsecureHTTP)
        // Consent for plaintext transport applies only when the URL the user approved was
        // already HTTP. Passing the flag for an HTTPS URL must never permit a downgrade.
        let permitsHTTPRedirects = parsed.scheme?.lowercased() == "http"

        // Resume data must be a property-list DICTIONARY (URLSession's format); anything else
        // raises an ObjC exception inside downloadTask(withResumeData:) — even a bare string
        // parses as a legacy plist — so validate the shape and fall back to a fresh download.
        let usableResumeData = resumeData.flatMap { data in
            ((try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]) != nil
                ? data : nil
        }
        let (tmpURL, response): (URL, URLResponse)
        if let usableResumeData {
            let resumedTask = session.downloadTask(withResumeData: usableResumeData)
            let resumedURL = resumedTask.currentRequest?.url ?? resumedTask.originalRequest?.url
            if DirectRedirectGuard.permitsTransfer(to: resumedURL, permitsHTTPRedirects: permitsHTTPRedirects) {
                do {
                    (tmpURL, response) = try await Self.perform(
                        task: resumedTask,
                        tmpDirectory: tmpDirectory, permitsHTTPRedirects: permitsHTTPRedirects,
                        onProgress: onProgress, onResumeData: onResumeData
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as DirectDownloadError {
                    throw error
                } catch {
                    // Stale or server-rejected resume data: restart from scratch instead of failing.
                    (tmpURL, response) = try await Self.perform(
                        task: session.downloadTask(with: parsed),
                        tmpDirectory: tmpDirectory, permitsHTTPRedirects: permitsHTTPRedirects,
                        onProgress: onProgress, onResumeData: onResumeData
                    )
                }
            } else {
                // Resume data is persisted external input. Never start a task whose embedded URL
                // would bypass the transport policy of the URL the user approved.
                resumedTask.cancel()
                (tmpURL, response) = try await Self.perform(
                    task: session.downloadTask(with: parsed),
                    tmpDirectory: tmpDirectory, permitsHTTPRedirects: permitsHTTPRedirects,
                    onProgress: onProgress, onResumeData: onResumeData
                )
            }
        } else {
            (tmpURL, response) = try await Self.perform(
                task: session.downloadTask(with: parsed),
                tmpDirectory: tmpDirectory, permitsHTTPRedirects: permitsHTTPRedirects,
                onProgress: onProgress, onResumeData: onResumeData
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
        permitsHTTPRedirects: Bool,
        onProgress: @Sendable @escaping (DownloadProgress) -> Void,
        onResumeData: (@Sendable (Data) -> Void)?
    ) async throws -> (URL, URLResponse) {
        let executor = DirectDownloadExecutor(
            tmpDirectory: tmpDirectory,
            permitsHTTPRedirects: permitsHTTPRedirects,
            maximumRedirects: maximumRedirects,
            onProgress: onProgress,
            onResumeData: onResumeData
        )
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
    public func headInfo(
        url: String,
        allowInsecureHTTP: Bool = false,
        session: URLSession = makeSession()
    ) async throws -> DirectFileInfo {
        let parsed = try Self.validatedURL(url, allowInsecureHTTP: allowInsecureHTTP)
        let permitsHTTPRedirects = parsed.scheme?.lowercased() == "http"
        var request = URLRequest(url: parsed)
        request.httpMethod = "HEAD"
        let redirectDelegate = DirectRedirectDelegate(
            permitsHTTPRedirects: permitsHTTPRedirects,
            maximumRedirects: Self.maximumRedirects
        )
        let (_, response) = try await session.data(for: request, delegate: redirectDelegate)
        if let redirectError = redirectDelegate.validationError(for: response) {
            throw redirectError
        }
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

    private static func validatedURL(_ raw: String, allowInsecureHTTP: Bool) throws -> URL {
        guard let parsed = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw DirectDownloadError.invalidURL
        }
        let scheme = parsed.scheme?.lowercased()
        if scheme == "http", !allowInsecureHTTP { throw DirectDownloadError.insecureScheme }
        guard scheme == "https" || scheme == "http" else { throw DirectDownloadError.invalidURL }
        return parsed
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

/// Per-task redirect policy. URLSession follows redirects automatically unless its task delegate
/// rejects them, so every hop must be revalidated rather than trusting only the pasted URL.
final class DirectRedirectGuard: @unchecked Sendable {
    private let lock = NSLock()
    private let permitsHTTPRedirects: Bool
    private let maximumRedirects: Int
    private var redirectCount = 0
    private var storedRejection: DirectDownloadError?

    init(permitsHTTPRedirects: Bool, maximumRedirects: Int) {
        self.permitsHTTPRedirects = permitsHTTPRedirects
        self.maximumRedirects = maximumRedirects
    }

    static func permitsTransfer(to url: URL?, permitsHTTPRedirects: Bool) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "https" || (scheme == "http" && permitsHTTPRedirects)
    }

    func requestToFollow(_ request: URLRequest, from response: HTTPURLResponse) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        guard storedRejection == nil else { return nil }

        redirectCount += 1
        if redirectCount > maximumRedirects {
            storedRejection = .tooManyRedirects
            return nil
        }
        guard let sourceScheme = response.url?.scheme?.lowercased(),
              sourceScheme == "https" || sourceScheme == "http"
        else {
            storedRejection = .invalidURL
            return nil
        }
        if request.url?.scheme?.lowercased() == "http", sourceScheme == "https" {
            storedRejection = .insecureScheme
            return nil
        }
        if let error = schemeError(for: request.url) {
            storedRejection = error
            return nil
        }
        return request
    }

    var rejection: DirectDownloadError? {
        lock.lock()
        defer { lock.unlock() }
        return storedRejection
    }

    func validationError(for response: URLResponse) -> DirectDownloadError? {
        if let rejection { return rejection }
        return schemeError(for: response.url)
    }

    private func schemeError(for url: URL?) -> DirectDownloadError? {
        guard let scheme = url?.scheme?.lowercased() else { return .invalidURL }
        guard scheme == "https" || scheme == "http" else { return .invalidURL }
        return Self.permitsTransfer(to: url, permitsHTTPRedirects: permitsHTTPRedirects)
            ? nil : .insecureScheme
    }
}

/// HEAD/data-task delegate counterpart of DirectDownloadExecutor.
final class DirectRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let redirectGuard: DirectRedirectGuard

    init(permitsHTTPRedirects: Bool, maximumRedirects: Int) {
        self.redirectGuard = DirectRedirectGuard(
            permitsHTTPRedirects: permitsHTTPRedirects,
            maximumRedirects: maximumRedirects
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(redirectGuard.requestToFollow(request, from: response))
    }

    func validationError(for response: URLResponse) -> DirectDownloadError? {
        redirectGuard.validationError(for: response)
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
    private let redirectGuard: DirectRedirectGuard
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var movedURL: URL?

    init(
        tmpDirectory: URL,
        permitsHTTPRedirects: Bool = false,
        maximumRedirects: Int = DirectDownloadService.maximumRedirects,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void,
        onResumeData: (@Sendable (Data) -> Void)?
    ) {
        self.tmpDirectory = tmpDirectory
        self.onProgress = onProgress
        self.onResumeData = onResumeData
        self.redirectGuard = DirectRedirectGuard(
            permitsHTTPRedirects: permitsHTTPRedirects,
            maximumRedirects: maximumRedirects
        )
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

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(redirectGuard.requestToFollow(request, from: response))
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
        if let rejection = redirectGuard.rejection {
            if let moved { try? FileManager.default.removeItem(at: moved) }
            continuation?.resume(throwing: rejection)
        } else if let error {
            if let moved { try? FileManager.default.removeItem(at: moved) }
            if let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                onResumeData?(resume)
            }
            if (error as? URLError)?.code == .cancelled {
                continuation?.resume(throwing: CancellationError())
            } else {
                continuation?.resume(throwing: error)
            }
        } else if let moved, let response = task.response {
            if let redirectError = redirectGuard.validationError(for: response) {
                try? FileManager.default.removeItem(at: moved)
                continuation?.resume(throwing: redirectError)
            } else {
                continuation?.resume(returning: (moved, response))
            }
        } else {
            continuation?.resume(throwing: URLError(.cannotWriteToFile))
        }
    }
}
