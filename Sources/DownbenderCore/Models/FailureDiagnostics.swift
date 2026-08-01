import Foundation

public enum DiagnosticOperation: String, Codable, Sendable {
    case analysis
    case download
    case directDownload

    var label: String {
        switch self {
        case .analysis: "Analysis"
        case .download: "Media download"
        case .directDownload: "Direct download"
        }
    }
}

/// The useful, privacy-safe part of one failed yt-dlp process.
public struct YtdlpFailureDetails: Equatable, Sendable {
    private static let outputByteLimit = 40 * 1_024

    public let exitCode: Int32
    public let summary: String
    public let output: String

    public init(exitCode: Int32, summary: String, output: String) {
        self.exitCode = exitCode
        self.summary = DiagnosticSanitizer.sanitizeAndLimit(summary, maxBytes: 2_048)
        self.output = DiagnosticSanitizer.sanitizeAndLimit(output, maxBytes: Self.outputByteLimit)
    }

    public init(result: ProcessResult) {
        let raw = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = raw.split(whereSeparator: \.isNewline).map(String.init)
        let actionable = lines.last(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("[debug]")
                && (YtdlpErrorHint.hint(for: $0) != nil
                    || TransientFailure.isTransientMessage($0))
        })
        let summary = actionable ?? lines.last(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("ERROR")
        }) ?? lines.last(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[debug]")
        }) ?? "yt-dlp failed with no error message."
        self.init(
            exitCode: result.exitCode,
            summary: summary,
            output: raw.isEmpty ? summary : raw
        )
    }
}

public struct FailureAttempt: Codable, Equatable, Sendable {
    static let outputByteLimit = 12 * 1_024

    public let number: Int
    public let exitCode: Int32?
    public let detailed: Bool
    public let summary: String
    public let output: String

    public init(
        number: Int,
        exitCode: Int32?,
        detailed: Bool,
        summary: String,
        output: String
    ) {
        self.number = max(1, number)
        self.exitCode = exitCode
        self.detailed = detailed
        self.summary = DiagnosticSanitizer.sanitizeAndLimit(summary, maxBytes: 2_048)
        self.output = DiagnosticSanitizer.sanitizeAndLimit(
            output.isEmpty ? summary : output,
            maxBytes: Self.outputByteLimit
        )
    }

    private enum CodingKeys: String, CodingKey {
        case number, exitCode, detailed, summary, output
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            number: try values.decode(Int.self, forKey: .number),
            exitCode: try values.decodeIfPresent(Int32.self, forKey: .exitCode),
            detailed: try values.decode(Bool.self, forKey: .detailed),
            summary: try values.decode(String.self, forKey: .summary),
            output: try values.decode(String.self, forKey: .output)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(number, forKey: .number)
        try values.encodeIfPresent(exitCode, forKey: .exitCode)
        try values.encode(detailed, forKey: .detailed)
        try values.encode(summary, forKey: .summary)
        try values.encode(output, forKey: .output)
    }
}

/// Bounded diagnostics stored on a failed queue item. Every string has already been redacted;
/// `report` applies the sanitizer again before anything reaches the UI or clipboard.
public struct FailureDiagnostics: Codable, Equatable, Sendable {
    public let appVersion: String
    public let systemVersion: String
    public let host: String
    public let operation: DiagnosticOperation
    public let engineChannel: YtdlpEngineChannel?
    public let engineVersion: String?
    public let outputDescription: String?
    public let includeSubtitles: Bool?
    public let attempts: [FailureAttempt]

    public init(
        appVersion: String = Downbender.version,
        systemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        host: String,
        operation: DiagnosticOperation,
        engineChannel: YtdlpEngineChannel?,
        engineVersion: String?,
        outputDescription: String?,
        includeSubtitles: Bool?,
        attempts: [FailureAttempt]
    ) {
        self.appVersion = DiagnosticSanitizer.sanitizeAndLimit(appVersion, maxBytes: 256)
        self.systemVersion = DiagnosticSanitizer.sanitizeAndLimit(systemVersion, maxBytes: 512)
        self.host = DiagnosticSanitizer.sanitizeAndLimit(host, maxBytes: 512)
        self.operation = operation
        self.engineChannel = engineChannel
        self.engineVersion = engineVersion.map {
            DiagnosticSanitizer.sanitizeAndLimit($0, maxBytes: 512)
        }
        self.outputDescription = outputDescription.map {
            DiagnosticSanitizer.sanitizeAndLimit($0, maxBytes: 512)
        }
        self.includeSubtitles = includeSubtitles
        self.attempts = Array(attempts.suffix(3))
    }

    public var report: String {
        var lines = [
            "Downbender diagnostics",
            "App: \(appVersion)",
            "System: \(systemVersion)",
            "Operation: \(operation.label)",
            "Host: \(host.isEmpty ? "unknown" : host)",
        ]
        if let engineChannel {
            lines.append(
                "Engine: \(engineChannel.displayName) · \(engineVersion ?? "version unknown")"
            )
        } else if operation == .directDownload {
            lines.append("Engine: Native URLSession")
        } else {
            lines.append("Engine: yt-dlp · channel and version unknown")
        }
        if let outputDescription { lines.append("Output: \(outputDescription)") }
        if let includeSubtitles {
            lines.append("Subtitles: \(includeSubtitles ? "included" : "not included")")
        }
        lines.append("Attempts: \(attempts.count)")

        for attempt in attempts {
            lines += [
                "",
                "Attempt \(attempt.number)\(attempt.detailed ? " · detailed logging" : "")",
                "Exit code: \(attempt.exitCode.map(String.init) ?? "unknown")",
                "Summary: \(attempt.summary)",
                "Output:",
                attempt.output,
            ]
        }
        return DiagnosticSanitizer.sanitizeAndLimit(
            lines.joined(separator: "\n"),
            maxBytes: 48 * 1_024
        )
    }

    public static func host(from rawURL: String) -> String {
        guard let host = URLComponents(string: rawURL)?.host?.lowercased(), !host.isEmpty else {
            return "unknown"
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private enum CodingKeys: String, CodingKey {
        case appVersion, systemVersion, host, operation, engineChannel, engineVersion
        case outputDescription, includeSubtitles, attempts
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            appVersion: try values.decode(String.self, forKey: .appVersion),
            systemVersion: try values.decode(String.self, forKey: .systemVersion),
            host: try values.decode(String.self, forKey: .host),
            operation: try values.decode(DiagnosticOperation.self, forKey: .operation),
            engineChannel: try values.decodeIfPresent(YtdlpEngineChannel.self, forKey: .engineChannel),
            engineVersion: try values.decodeIfPresent(String.self, forKey: .engineVersion),
            outputDescription: try values.decodeIfPresent(String.self, forKey: .outputDescription),
            includeSubtitles: try values.decodeIfPresent(Bool.self, forKey: .includeSubtitles),
            attempts: try values.decode([FailureAttempt].self, forKey: .attempts)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(appVersion, forKey: .appVersion)
        try values.encode(systemVersion, forKey: .systemVersion)
        try values.encode(host, forKey: .host)
        try values.encode(operation, forKey: .operation)
        try values.encodeIfPresent(engineChannel, forKey: .engineChannel)
        try values.encodeIfPresent(engineVersion, forKey: .engineVersion)
        try values.encodeIfPresent(outputDescription, forKey: .outputDescription)
        try values.encodeIfPresent(includeSubtitles, forKey: .includeSubtitles)
        try values.encode(attempts, forKey: .attempts)
    }
}

enum DiagnosticSanitizer {
    private static let sensitiveOptions =
        "cookies(?:-from-browser)?|username|password|video-password|proxy|client-certificate-key|netrc-location"
    private static let sensitiveKeys =
        "access[_-]?token|token|auth(?:orization)?|password|passwd|api[_-]?key|signature|sig|session(?:id)?|jwt|key|cookies?|set[_-]?cookie"

    static func sanitize(_ text: String) -> String {
        var safe = text
        safe = replace(
            #"(?im)^\s*\[debug\]\s+Command-line config:.*$"#,
            in: safe,
            with: "[debug] Command-line config: <redacted>"
        )
        safe = replace(
            #"(?im)^(\s*(?:\[[^\]\r\n]+\]\s*)?(?:Authorization|Proxy-Authorization|Cookie|Set-Cookie|X-Api-Key)\s*:)\s*.*$"#,
            in: safe,
            with: "$1 <redacted>"
        )
        safe = replace(
            #"(?im)([\"']?(?:Authorization|Proxy-Authorization|Cookie|Set-Cookie|X-Api-Key)[\"']?\s*[:=]\s*).*$"#,
            in: safe,
            with: "$1<redacted>"
        )
        safe = replace(
            "(?i)(--(?:\(sensitiveOptions))\\s+)(?:\"[^\"]*\"|'[^']*'|\\S+)",
            in: safe,
            with: "$1<redacted>"
        )
        safe = replace(
            "(?i)(--(?:\(sensitiveOptions))=)(?:\"[^\"]*\"|'[^']*'|\\S+)",
            in: safe,
            with: "$1<redacted>"
        )
        safe = replace(#"(?i)([\"'])file://[^\r\n\"']+\1"#, in: safe, with: "<path>")
        safe = replace(#"(?i)\bfile://[^\r\n<>\"']+"#, in: safe, with: "<path>")
        safe = replace(#"(?i)\b(?:https?|ftp)://[^\s<>\"']+"#, in: safe, with: "<url>")
        safe = replace(
            "(?i)([\"']?(?:\(sensitiveKeys))[\"']?\\s*[:=]\\s*)(?:\"[^\"]*\"|'[^']*'|[^\\s&,;]+)",
            in: safe,
            with: "$1<redacted>"
        )
        safe = replace(
            #"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/:=-]+"#,
            in: safe,
            with: "$1 <redacted>"
        )
        safe = replace(
            #"(?i)([\"'])/(?:Users|home|private|tmp|var|Volumes|Applications|Library|opt|usr|etc)(?:/[^\r\n\"']+)+\1"#,
            in: safe,
            with: "<path>"
        )
        safe = replace(
            #"(?i)(?<![A-Za-z0-9])/(?:Users|home|private|tmp|var|Volumes|Applications|Library|opt|usr|etc)(?:/[^\r\n<>\"']+)+"#,
            in: safe,
            with: "<path>"
        )
        safe = replace(#"(?i)([\"'])~/(?:[^\r\n\"']+)+\1"#, in: safe, with: "<path>")
        safe = replace(#"(?i)(?<![A-Za-z0-9])~/(?:[^\r\n<>\"']+)+"#, in: safe, with: "<path>")
        safe = replace(#"(?i)([\"'])\b[A-Z]:\\[^\r\n\"']+\1"#, in: safe, with: "<path>")
        safe = replace(#"(?i)\b[A-Z]:\\[^\r\n<>\"']+"#, in: safe, with: "<path>")
        return safe
    }

    static func sanitizeAndLimit(_ text: String, maxBytes: Int) -> String {
        bounded(sanitize(text), maxBytes: maxBytes)
    }

    static func bounded(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let marker = "\n[… output truncated …]\n"
        guard maxBytes > marker.utf8.count else {
            return prefix(text, maxBytes: maxBytes)
        }
        let available = maxBytes - marker.utf8.count
        let headBytes = available / 3
        let tailBytes = available - headBytes
        return prefix(text, maxBytes: headBytes)
            + marker
            + suffix(text, maxBytes: tailBytes)
    }

    private static func prefix(_ text: String, maxBytes: Int) -> String {
        var byteCount = 0
        var end = text.startIndex
        for character in text {
            let next = String(character).utf8.count
            guard byteCount + next <= maxBytes else { break }
            byteCount += next
            end = text.index(end, offsetBy: 1)
        }
        return String(text[..<end])
    }

    private static func suffix(_ text: String, maxBytes: Int) -> String {
        var byteCount = 0
        var start = text.endIndex
        for character in text.reversed() {
            let next = String(character).utf8.count
            guard byteCount + next <= maxBytes else { break }
            byteCount += next
            start = text.index(before: start)
        }
        return String(text[start...])
    }

    private static func replace(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: replacement
        )
    }
}
