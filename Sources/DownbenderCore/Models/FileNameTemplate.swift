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

    private struct Placeholder {
        let field: String
        let source: String
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
