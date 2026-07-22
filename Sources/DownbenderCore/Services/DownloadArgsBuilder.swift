import Foundation

public enum DownloadArgsBuilder {
    // Field order is coupled to ProgressParser.parse: pct, bytes (down/total), speed, eta.
    // total_bytes can be None on HLS → falls back to total_bytes_estimate (alternatives syntax).
    public static let progressTemplate =
        "download:\(ProgressParser.templateLinePrefix) %(progress._percent_str)s %(progress.downloaded_bytes)s %(progress.total_bytes,progress.total_bytes_estimate)s %(progress._speed_str)s %(progress._eta_str)s"

    /// Flags common to EVERY yt-dlp invocation (probe and download).
    /// `noPlaylist: false` only when the user explicitly asked to expand a watch+list URL.
    static func baseArgs(denoURL: URL?, cookiesBrowser: String?, noPlaylist: Bool = true) -> [String] {
        // 30 s per network read: a dead socket aborts instead of hanging forever; yt-dlp's
        // own --retries picks it up. Applies to probe AND download (both build on baseArgs).
        var args = ["--no-config", "--socket-timeout", "30"]
        if noPlaylist { args.append("--no-playlist") }
        if let denoURL { args += ["--js-runtimes", "deno:\(denoURL.path)"] }
        if let cookiesBrowser { args += ["--cookies-from-browser", cookiesBrowser] }
        return args
    }

    public static func arguments(
        url: String,
        format: DownloadFormat,
        destination: URL,
        tmpDirectory: URL,
        ffmpegDirectory: URL,
        denoURL: URL? = nil,
        cookiesBrowser: String? = nil,
        includeSubtitles: Bool = false,
        useTVClient: Bool = false
    ) -> [String] {
        var args = baseArgs(denoURL: denoURL, cookiesBrowser: cookiesBrowser)
        args += [
            // --print implies quiet: without --no-quiet yt-dlp emits neither the
            // "[download] Destination:" lines (unified-progress phases) nor "[Merger]".
            "--no-quiet",
            "--newline",
            "--progress-template", progressTemplate,
            "--progress",
            "--print", "after_move:DBPATH %(filepath)s",
            "--retries", "10",
            "--fragment-retries", "10",
            "--ffmpeg-location", ffmpegDirectory.path,
            "-P", destination.path,
            "-P", "temp:\(tmpDirectory.path)",
            "-o", "%(title)s.%(ext)s",
            // lang after proto: preserves the ORIGINAL audio track (YouTube generates AI dubs with language_preference=-1); before proto it would promote muxed HLS.
            "-S", "res,fps,proto,lang,br",
        ]
        if useTVClient {
            // Last resort against a persistent 403: the TV client falls outside YouTube's PO-token enforcement.
            args += ["--extractor-args", "youtube:player_client=tv"]
        }

        switch format {
        case .video(let height):
            // Output is always mp4. The bundled ffmpeg SIGSEGVs muxing VP9/AV1 into mp4, so the
            // merge is restricted to avc1 video + m4a audio (YouTube serves avc1 up to 1080p,
            // the panel's cap). Falls back to progressive mp4 for rare videos without avc1.
            let selector = "bv*[height=\(height)][vcodec^=avc1]+ba[ext=m4a]/bv*[height<=\(height)][vcodec^=avc1]+ba[ext=m4a]/b[height<=\(height)][ext=mp4]/b[height<=\(height)]"
            args += ["-f", selector, "--merge-output-format", "mp4"]
            if includeSubtitles {
                // Creator-uploaded tracks only (never --write-auto-subs). Embedded via the bundled
                // ffmpeg (mov_text) and sidecars removed. live_chat is chat JSON, not a subtitle.
                args += ["--embed-subs", "--sub-langs", "all,-live_chat"]
            }
        case .audioMP3:
            // "ba/b": prefer audio-only; on muxed-only sites (e.g. archive.org) fall back
            // to the best muxed file and let -x extract its audio.
            args += ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "0"]
        }

        args.append(url)
        return args
    }
}
