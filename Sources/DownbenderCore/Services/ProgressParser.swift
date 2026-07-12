public enum ProgressParser {
    public static let templateLinePrefix = "DBPROG"

    /// Parses "DBPROG <pct>% <downloaded> <total> <speed> <eta>". Bytes go BEFORE speed/eta
    /// on purpose: yt-dlp can emit speed with an internal space ("Unknown B/s"), shifting later fields.
    public static func parse(line: String) -> DownloadProgress? {
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
}
