import Foundation

/// Splits pasted text into downloadable URLs so pasting a list enqueues them all.
public enum URLBatch {
    /// Whitespace/newline-separated http(s) tokens. With none, the trimmed text travels
    /// as ONE entry (today's behavior: the probe produces the honest error).
    public static func split(_ text: String) -> [String] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let webURLs = tokens.filter(isWebURL)
        if !webURLs.isEmpty { return webURLs }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [trimmed]
    }

    /// Strict variant for drag-and-drop. A drop is external input, so unlike manual text
    /// entry it must contain one or more complete web URLs; local files and other schemes
    /// are ignored instead of creating cards that can never download.
    public static func droppedWebURLs(_ items: [String]) -> [String] {
        items.flatMap { text in
            text.split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .filter(isWebURL)
        }
    }

    private static func isWebURL(_ text: String) -> Bool {
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false
        else { return false }
        return true
    }
}
