import Foundation

/// Central classifier for failures a FRESH attempt can plausibly clear (used by the download
/// retry loop, the probe retry, and the direct-download retry).
public enum TransientFailure {
    /// URLError codes worth retrying on the URLSession (direct download) path.
    public static let transientURLCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
    ]

    public static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError { return transientURLCodes.contains(urlError.code) }
        return isTransientMessage(error.localizedDescription)
    }

    /// yt-dlp reports errors as prose on stderr: YouTube 403s are intermittent (a fresh
    /// invocation renegotiates signed URLs) and DNS blips on the ephemeral googlevideo
    /// hosts clear on re-extraction.
    public static func isTransientMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        if message.contains("403") || lower.contains("forbidden") { return true }
        return lower.contains("failed to resolve")
            || lower.contains("nodename nor servname")
            || lower.contains("temporary failure in name resolution")
            || lower.contains("name or service not known")
            || lower.contains("getaddrinfo")
    }
}
