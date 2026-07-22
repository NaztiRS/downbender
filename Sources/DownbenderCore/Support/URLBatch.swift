import Foundation

/// Splits pasted text into downloadable URLs so pasting a list enqueues them all.
public enum URLBatch {
    /// Whitespace/newline-separated http(s) tokens. With none, the trimmed text travels
    /// as ONE entry (today's behavior: the probe produces the honest error).
    public static func split(_ text: String) -> [String] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let webURLs = tokens.filter { token in
            guard let url = URL(string: token), let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "https" || scheme == "http"
        }
        if !webURLs.isEmpty { return webURLs }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [trimmed]
    }
}
