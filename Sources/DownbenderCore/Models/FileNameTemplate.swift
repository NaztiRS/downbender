import Foundation

/// A deliberately small, filename-only subset of yt-dlp's output-template language.
/// Downbender owns the destination path, so literals cannot introduce a directory and the
/// extension placeholder stays stable across download, merge, retry, and resume operations.
public enum FileNameTemplate {
    public static let defaultValue = "%(title)s.%(ext)s"
    public static let maximumLength = 200
    public static let supportedFields = [
        "title", "id", "uploader", "uploader_id", "channel", "channel_id",
        "upload_date", "release_date", "duration_string", "resolution",
        "height", "width", "format_id", "extractor", "extractor_key",
    ]

    /// Common choices shown by Settings. The exact strings remain the persisted contract so
    /// queued downloads and older preferences keep the template they originally captured.
    public enum Preset: String, CaseIterable, Identifiable, Sendable {
        case title
        case channelAndTitle
        case uploadDateAndTitle
        case titleAndIdentifier

        public var id: String { rawValue }

        public var template: String {
            switch self {
            case .title:
                FileNameTemplate.defaultValue
            case .channelAndTitle:
                "%(channel)s — %(title)s.%(ext)s"
            case .uploadDateAndTitle:
                "%(upload_date)s — %(title)s.%(ext)s"
            case .titleAndIdentifier:
                "%(title)s [%(id)s].%(ext)s"
            }
        }

        public static func matching(_ value: String) -> Self? {
            guard let normalized = FileNameTemplate.normalized(value) else { return nil }
            return allCases.first { $0.template == normalized }
        }
    }

    private struct Placeholder {
        let field: String
        let source: String

        var isSimpleString: Bool {
            source == "%(\(field))s"
        }
    }

    private static let supportedFieldSet = Set(supportedFields + ["ext"])
    private static let conversions = Set("diouxXeEfFgGcrsBjhlqDSU")
    private static let formatFlags = Set("#0- +")
    private static let lengthModifiers = Set("hlL")

    public static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return validationMessage(for: trimmed) == nil ? trimmed : nil
    }

    public static func validationMessage(for value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter a file name template." }
        if trimmed.count > maximumLength {
            return "Keep the template under \(maximumLength) characters."
        }
        if trimmed.first == "-" {
            return "The file name cannot begin with “-”."
        }
        if trimmed.first == "~" || trimmed.contains("$") {
            return "Home and environment-variable expansion are not allowed."
        }
        if trimmed.contains("/") || trimmed.contains("\\") || trimmed.contains(":") {
            return "Use a file name only; folders and “:” are not allowed."
        }
        if trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            return "Control characters are not allowed."
        }
        guard let placeholders = parsePlaceholders(trimmed) else {
            return "Use supported fields such as %(title)s, and write a literal % as %%."
        }
        let extensions = placeholders.filter { $0.field == "ext" }
        guard extensions.count == 1, extensions[0].source == "%(ext)s",
              trimmed.hasSuffix(".%(ext)s") else {
            return "End the template with exactly one .%(ext)s."
        }
        guard placeholders.contains(where: { $0.field != "ext" }) else {
            return "Include a naming field such as %(title)s or %(id)s."
        }
        return nil
    }

    /// Invalid values never reach yt-dlp, including corrupted preferences restored from disk.
    public static func outputTemplate(for value: String) -> String {
        normalized(value) ?? defaultValue
    }

    /// Renders a safe, representative filename for Settings without invoking yt-dlp.
    /// Advanced formatting returns nil instead of presenting an inaccurate result.
    public static func example(for value: String) -> String? {
        guard let normalized = normalized(value),
              let placeholders = parsePlaceholders(normalized),
              placeholders.allSatisfy(\.isSimpleString)
        else { return nil }

        let samples = [
            "title": "My video",
            "id": "a1b2c3",
            "uploader": "Example Creator",
            "uploader_id": "creator123",
            "channel": "Example Channel",
            "channel_id": "UC123",
            "upload_date": "20260725",
            "release_date": "20260725",
            "duration_string": "12m34s",
            "resolution": "1920x1080",
            "height": "1080",
            "width": "1920",
            "format_id": "137+140",
            "extractor": "youtube",
            "extractor_key": "Youtube",
            "ext": "mp4",
        ]

        // Protect escaped placeholders such as `%%(title)s` before substituting real fields.
        // Validation excludes control characters, so the marker cannot collide with input.
        let escapedPercentMarker = "\u{0}"
        var rendered = normalized.replacingOccurrences(of: "%%", with: escapedPercentMarker)
        for placeholder in placeholders {
            guard let sample = samples[placeholder.field] else { continue }
            rendered = rendered.replacingOccurrences(of: placeholder.source, with: sample)
        }
        return rendered.replacingOccurrences(of: escapedPercentMarker, with: "%")
    }

    private static func parsePlaceholders(_ value: String) -> [Placeholder]? {
        let characters = Array(value)
        var placeholders: [Placeholder] = []
        var index = 0

        while index < characters.count {
            guard characters[index] == "%" else {
                index += 1
                continue
            }
            guard index + 1 < characters.count else { return nil }
            if characters[index + 1] == "%" {
                index += 2
                continue
            }
            guard characters[index + 1] == "(" else { return nil }

            let placeholderStart = index
            var cursor = index + 2
            let fieldStart = cursor
            while cursor < characters.count, characters[cursor] != ")" { cursor += 1 }
            guard cursor < characters.count, cursor > fieldStart else { return nil }
            let field = String(characters[fieldStart..<cursor])
            guard supportedFieldSet.contains(field) else { return nil }

            cursor += 1
            let formatStart = cursor
            while cursor < characters.count, !conversions.contains(characters[cursor]) {
                cursor += 1
            }
            guard cursor < characters.count else { return nil }
            guard isValidFormat(Array(characters[formatStart...cursor])) else { return nil }
            let source = String(characters[placeholderStart...cursor])
            placeholders.append(Placeholder(field: field, source: source))
            index = cursor + 1
        }
        return placeholders
    }

    /// Validates the documented printf-shaped suffix while bounding any explicit width or
    /// precision. In particular, `*` is not accepted because it asks for an argument yt-dlp
    /// does not have and can turn a Settings typo into a failed download.
    private static func isValidFormat(_ format: [Character]) -> Bool {
        guard let conversion = format.last, conversions.contains(conversion) else { return false }
        let end = format.count - 1
        var index = 0
        var seenFlags: Set<Character> = []
        while index < end, formatFlags.contains(format[index]) {
            // After one zero flag, another zero starts the width (e.g. `%(height)003d`).
            if format[index] == "0", seenFlags.contains("0") { break }
            guard seenFlags.insert(format[index]).inserted else { return false }
            index += 1
        }

        let widthStart = index
        while index < end, format[index].isNumber { index += 1 }
        if index > widthStart {
            guard let width = Int(String(format[widthStart..<index])),
                  width <= maximumLength else { return false }
        }

        if index < end, format[index] == "." {
            index += 1
            let precisionStart = index
            while index < end, format[index].isNumber { index += 1 }
            guard index > precisionStart,
                  let precision = Int(String(format[precisionStart..<index])),
                  precision <= maximumLength else { return false }
        }

        if index < end, lengthModifiers.contains(format[index]) { index += 1 }
        return index == end
    }
}
