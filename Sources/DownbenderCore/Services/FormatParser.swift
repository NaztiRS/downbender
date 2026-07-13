import Foundation

public enum FormatParser {
    public static func parseOutcome(_ data: Data) throws -> ProbeOutcome {
        if try JSONDecoder().decode(RawTypeProbe.self, from: data).type == "playlist" {
            return .playlist(try parsePlaylist(data))
        }
        return .video(try parse(data))
    }

    static func parsePlaylist(_ data: Data) throws -> PlaylistProbe {
        let raw = try JSONDecoder().decode(RawPlaylist.self, from: data)
        let entries = (raw.entries ?? []).compactMap { entry -> PlaylistEntry? in
            // An entry we cannot turn into a downloadable URL is useless: dropped.
            guard let url = entry.url ?? watchURL(entry) else { return nil }
            return PlaylistEntry(
                url: url,
                title: entry.title ?? url,
                thumbnailURL: entry.thumbnails?.last?.url.flatMap { URL(string: $0) } ?? youtubeThumbnailURL(entry)
            )
        }
        return PlaylistProbe(title: raw.title ?? "Playlist", entries: entries)
    }

    /// Flat entries may omit `url`; for YouTube the id is enough to rebuild it.
    private static func watchURL(_ entry: RawPlaylistEntry) -> String? {
        guard entry.ieKey == "Youtube", let id = entry.id else { return nil }
        return "https://www.youtube.com/watch?v=\(id)"
    }

    private static func youtubeThumbnailURL(_ entry: RawPlaylistEntry) -> URL? {
        guard entry.ieKey == "Youtube", let id = entry.id else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    }

    public static func parse(_ data: Data) throws -> ProbeResult {
        let raw = try JSONDecoder().decode(RawProbe.self, from: data)

        // Capped at 1080p by product decision (YouTube doesn't reliably serve >1080 on download).
        // vcodec == "none" means definitely no video track; nil means UNKNOWN (e.g. archive.org
        // direct files), so a format that declares a height counts as video.
        var heights = Set<Int>()
        for f in raw.formats {
            guard let h = f.height, h <= 1080 else { continue }
            if f.vcodec != "none" { heights.insert(h) }
        }
        var formats: [DownloadFormat] = heights.sorted(by: >).map { .video(height: $0) }

        // Same nil-vs-"none" rule: unknown acodec on a muxed file usually means audio exists ("ba/b" extracts it).
        let hasAudio = raw.formats.contains { $0.acodec != "none" }
        if hasAudio { formats.append(.audioMP3) }

        let approxSizeBytes = computeApproxSizeBytes(raw.formats, heights: heights)

        // live_chat is a live-chat JSON stream, not a subtitle; it would break --embed-subs.
        let subtitleLanguages = (raw.subtitles ?? [:]).keys.filter { $0 != "live_chat" }.sorted()

        return ProbeResult(
            videoID: raw.id,
            title: raw.title,
            thumbnailURL: raw.thumbnail.flatMap { URL(string: $0) },
            durationSeconds: raw.duration,
            availableFormats: formats,
            approxSizeBytes: approxSizeBytes,
            subtitleLanguages: subtitleLanguages
        )
    }

    /// Mirrors what the real selector (`bv*[height=H]+ba`) would pick. With separate audio the
    /// estimate is video + audio — yt-dlp merges even if the chosen video is muxed; on
    /// muxed-only sites the single file IS the download. Never invents: a required piece
    /// with no `filesize`/`filesize_approx` means no entry for that quality.
    private static func computeApproxSizeBytes(_ all: [RawFormat], heights: Set<Int>) -> [DownloadFormat: Int64] {
        func isHLS(_ f: RawFormat) -> Bool { (f.proto ?? "").contains("m3u8") }
        func size(_ f: RawFormat) -> Int64? { f.filesize ?? f.filesizeApprox }

        // -S proto prefers non-HLS; -S br breaks ties by higher bitrate.
        func isBetter(_ a: RawFormat, than b: RawFormat) -> Bool {
            let aHLS = isHLS(a)
            let bHLS = isHLS(b)
            if aHLS != bHLS { return bHLS && !aHLS }
            return (a.tbr ?? 0) > (b.tbr ?? 0)
        }

        func best(among candidates: [RawFormat]) -> RawFormat? {
            candidates.reduce(nil) { current, candidate in
                guard let current else { return candidate }
                return isBetter(candidate, than: current) ? candidate : current
            }
        }

        let audioOnly = all.filter { ($0.vcodec ?? "none") == "none" && ($0.acodec ?? "none") != "none" }
        let bestAudio = best(among: audioOnly)

        var result: [DownloadFormat: Int64] = [:]
        for h in heights {
            let videoCandidates = all.filter { $0.height == h && $0.vcodec != "none" }
            guard let bestVideo = best(among: videoCandidates), let vSize = size(bestVideo) else { continue }

            if let bestAudio {
                if let aSize = size(bestAudio) { result[.video(height: h)] = vSize + aSize }
            } else {
                result[.video(height: h)] = vSize
            }
        }
        return result
    }
}
