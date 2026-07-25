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
                thumbnailURL: entry.thumbnails?.last?.url.flatMap { URL(string: $0) } ?? youtubeThumbnailURL(entry),
                durationSeconds: entry.duration
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

        // vcodec == "none" means definitely no video track; nil means UNKNOWN (e.g. archive.org
        // direct files), so a format that declares a height counts as video.
        var heights = Set<Int>()
        for f in raw.formats {
            guard let h = f.height, h > 0 else { continue }
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
            subtitleLanguages: subtitleLanguages,
            extractor: raw.extractor
        )
    }

    /// Mirrors the two download profiles: AVC1/M4A at <=1080p and original codecs above it.
    /// A muxed format already includes audio; a video-only format must include the selected
    /// audio size. Never invents: missing metadata on a required stream means no estimate.
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
        let bestM4AAudio = best(among: audioOnly.filter { $0.ext == "m4a" })

        func estimatedSize(video: RawFormat, audio: RawFormat?) -> Int64? {
            guard let videoSize = size(video) else { return nil }
            // Anything except the explicit yt-dlp sentinel "none" may already be muxed.
            guard video.acodec == "none" else { return videoSize }
            guard let audio, let audioSize = size(audio) else { return nil }
            return videoSize + audioSize
        }

        var result: [DownloadFormat: Int64] = [:]
        for h in heights {
            let videoCandidates = all.filter { $0.height == h && $0.vcodec != "none" }
            if h <= 1080 {
                // The compatible selector prefers AVC1, then progressive MP4, before its
                // generic last resort. This also prevents a larger VP9 stream from skewing
                // an estimate for a row that promises MP4.
                let avc1 = videoCandidates.filter { $0.vcodec?.hasPrefix("avc1") == true }
                let progressiveMP4 = videoCandidates.filter { $0.ext == "mp4" && $0.acodec != "none" }
                guard let selected = best(among: avc1)
                    ?? best(among: progressiveMP4)
                    ?? best(among: videoCandidates)
                else { continue }
                if let estimate = estimatedSize(video: selected, audio: bestM4AAudio) {
                    result[.video(height: h)] = estimate
                }
            } else {
                // High-quality selector leads with video-only + best audio, then a muxed
                // exact-height fallback. Do not add audio twice to an already muxed file.
                let videoOnly = videoCandidates.filter { $0.acodec == "none" }
                let muxed = videoCandidates.filter { $0.acodec != "none" }
                guard let selected = best(among: videoOnly) ?? best(among: muxed) else { continue }
                if let estimate = estimatedSize(video: selected, audio: bestAudio) {
                    result[.video(height: h)] = estimate
                }
            }
        }
        return result
    }
}
