public enum ProgressParser {
    public static let templateLinePrefix = "DBPROG"

    /// Parses the pipe-delimited progress contract emitted by `DownloadArgsBuilder`.
    /// A legacy whitespace parser remains for persisted test fixtures and older engine output.
    public static func parse(line: String) -> DownloadProgress? {
        if line.hasPrefix("\(templateLinePrefix)|") {
            return parseStructured(line: line)
        }

        return parseLegacy(line: line)
    }

    private static func parseStructured(line: String) -> DownloadProgress? {
        let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(trimmed)
        guard fields.count == 9, fields[0] == templateLinePrefix,
              let pct = percentage(fields[2])
        else { return nil }

        let status: DownloadProgressStatus = switch fields[1] {
        case "downloading": .downloading
        case "finished": .finished
        default: .unknown
        }

        return DownloadProgress(
            fraction: pct / 100,
            speedText: displayValue(fields[7], hiding: ["NA", "Unknown", "Unknown B/s"]),
            etaText: displayValue(fields[8], hiding: ["NA", "Unknown"]),
            downloadedBytes: integer(fields[3]),
            totalBytes: integer(fields[4]),
            status: status,
            fragmentIndex: integer(fields[5]).map(Int.init),
            fragmentCount: integer(fields[6]).map(Int.init)
        )
    }

    private static func parseLegacy(line: String) -> DownloadProgress? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.first.map(String.init) == templateLinePrefix, parts.count >= 2 else { return nil }
        let token = parts[1]
        guard token.hasSuffix("%"), let pct = Double(token.dropLast()) else { return nil }
        // total_bytes_estimate arrives as a float ("123456.0"): parse via Double; "NA" → nil.
        let downloaded = parts.count >= 3 ? Double(parts[2]).map(Int64.init) : nil
        let total = parts.count >= 4 ? Double(parts[3]).map(Int64.init) : nil
        var speed = parts.count >= 5 ? String(parts[4]) : ""
        var eta = parts.count >= 6 ? String(parts[5]) : ""
        // Real artifacts: "Unknown B/s" splits across two tokens ("B/s" lands in the eta slot); final-line eta is "NA".
        if speed == "Unknown" { speed = ""; if eta == "B/s" { eta = "" } }
        if eta == "NA" || eta == "Unknown" { eta = "" }
        return DownloadProgress(
            fraction: pct / 100.0, speedText: speed, etaText: eta,
            downloadedBytes: downloaded, totalBytes: total
        )
    }

    private static func trimmed(_ value: Substring) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func percentage(_ value: String) -> Double? {
        guard value.hasSuffix("%") else { return nil }
        return Double(value.dropLast())
    }

    private static func integer(_ value: String) -> Int64? {
        guard value != "NA", let number = Double(value), number.isFinite else { return nil }
        return Int64(number)
    }

    private static func displayValue(_ value: String, hiding hidden: Set<String>) -> String {
        hidden.contains(value) ? "" : value
    }
}
