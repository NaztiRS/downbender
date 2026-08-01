import Foundation

/// Turns a few well-known yt-dlp errors into a friendly, actionable message. Returns nil for
/// anything unrecognized, so callers fall back to yt-dlp's raw text.
public enum YtdlpErrorHint {
    public enum SuggestedAction: Equatable, Sendable {
        case openSettings
    }

    public struct Hint: Equatable, Sendable {
        public let message: String
        public let suggestedAction: SuggestedAction?

        public init(message: String, suggestedAction: SuggestedAction? = nil) {
            self.message = message
            self.suggestedAction = suggestedAction
        }
    }

    public static func hint(for raw: String) -> Hint? {
        let lower = raw.lowercased()
        // YouTube's anti-bot gate: the fix is to read cookies from a browser (a Settings option).
        if lower.contains("not a bot") || lower.contains("sign in to confirm") || lower.contains("cookies-from-browser") {
            return Hint(
                message: "YouTube wants you to sign in. Pick your browser under “Browser cookies”, then try again.",
                suggestedAction: .openSettings
            )
        }
        // A DNS/name-resolution failure — a transient network or VPN hiccup, not the video itself.
        // (Downloads retry this silently; the message only surfaces if every retry still can't resolve.)
        if lower.contains("failed to resolve") || lower.contains("nodename nor servname")
            || lower.contains("temporary failure in name resolution") || lower.contains("name or service not known")
            || lower.contains("getaddrinfo") {
            return Hint(
                message: "Couldn't reach the server — a network or DNS hiccup. Check your connection (and VPN, if any), then try again."
            )
        }
        return nil
    }

    public static func friendly(_ raw: String) -> String? {
        hint(for: raw)?.message
    }

    /// Nightly is useful for extractor/site breakage, not for failures that already have a
    /// more specific remedy or originate outside yt-dlp's extractor code.
    public static func shouldOfferLatestFixes(for raw: String) -> Bool {
        if hint(for: raw)?.suggestedAction == .openSettings { return false }
        if TransientFailure.isTransientMessage(raw) { return false }

        let lower = raw.lowercased()
        let unrelatedFailures = [
            "this looks like a web page",
            "no space left",
            "disk full",
            "permission denied",
            "operation not permitted",
            "file name too long",
            "ffmpeg not found",
            "ffprobe not found",
            "no format selected",
        ]
        return !unrelatedFailures.contains(where: lower.contains)
    }
}
