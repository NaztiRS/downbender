import Foundation

/// Turns a few well-known yt-dlp errors into a friendly, actionable message. Returns nil for
/// anything unrecognized, so callers fall back to yt-dlp's raw text.
public enum YtdlpErrorHint {
    public static func friendly(_ raw: String) -> String? {
        let lower = raw.lowercased()
        // YouTube's anti-bot gate: the fix is to read cookies from a browser (a Settings option).
        if lower.contains("not a bot") || lower.contains("sign in to confirm") || lower.contains("cookies-from-browser") {
            return "YouTube wants you to sign in. Open Settings (⌘,), pick your browser under “Browser cookies”, then try again."
        }
        return nil
    }
}
