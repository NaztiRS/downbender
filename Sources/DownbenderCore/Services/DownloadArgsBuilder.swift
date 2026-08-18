import Foundation

public enum DownloadArgsBuilder {
    // Field order is coupled to ProgressParser.parse: pct, bytes (down/total), speed, eta.
    // total_bytes can be None on HLS → falls back to total_bytes_estimate (alternatives syntax).
    public static let progressTemplate =
        "download:\(ProgressParser.templateLinePrefix) %(progress._percent_str)s %(progress.downloaded_bytes)s %(progress.total_bytes,progress.total_bytes_estimate)s %(progress._speed_str)s %(progress._eta_str)s"

    /// Flags common to EVERY yt-dlp invocation (probe and download).
    /// `noPlaylist: false` only when the user explicitly asked to expand a watch+list URL.
    static func baseArgs(
        denoURL: URL?,
        cookiesBrowser: String?,
        noPlaylist: Bool = true,
        detailedDiagnostics: Bool = false
    ) -> [String] {
        // 30 s per network read: a dead socket aborts instead of hanging forever; yt-dlp's
        // own --retries picks it up. Applies to probe AND download (both build on baseArgs).
        var args = ["--no-config", "--socket-timeout", "30"]
        if noPlaylist { args.append("--no-playlist") }
        if detailedDiagnostics { args.append("--verbose") }
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
        fileNameTemplate: String = FileNameTemplate.defaultValue,
        includeSubtitles: Bool = false,
        detailedDiagnostics: Bool = false,
        useTVClient: Bool = false,
        useOriginalCodecMKV: Bool = false
    ) -> [String] {
        var args = baseArgs(
            denoURL: denoURL,
            cookiesBrowser: cookiesBrowser,
            detailedDiagnostics: detailedDiagnostics
        )
        args += [
            // --print implies quiet: without --no-quiet yt-dlp emits neither the
            // "[download] Destination:" lines (unified-progress phases) nor "[Merger]".
            "--no-quiet",
            "--newline",
            "--progress-delta", "0.25",
            "--progress-template", progressTemplate,
            "--progress",
            "--print", "after_move:DBPATH %(filepath)s",
            "--retries", "10",
            "--fragment-retries", "10",
            "--ffmpeg-location", ffmpegDirectory.path,
            "-P", destination.path,
            "-P", "temp:\(tmpDirectory.path)",
            "-o", FileNameTemplate.outputTemplate(for: fileNameTemplate),
            // lang after proto: preserves the ORIGINAL audio track (YouTube generates AI dubs with language_preference=-1); before proto it would promote muxed HLS.
            "-S", "res,fps,proto,lang,br",
        ]
        if useTVClient {
            // Last resort against a persistent 403: the TV client falls outside YouTube's PO-token enforcement.
            args += ["--extractor-args", "youtube:player_client=tv"]
        }

        switch format {
        case .video(let height) where height <= 1080 && !useOriginalCodecMKV:
            // Compatibility profile. The bundled ffmpeg SIGSEGVs muxing VP9/AV1 into MP4,
            // so qualities up to 1080p retain the proven AVC1 + M4A selector.
            let selector = "bv*[height=\(height)][vcodec^=avc1]+ba[ext=m4a]/bv*[height<=\(height)][vcodec^=avc1]+ba[ext=m4a]/b[height<=\(height)][ext=mp4]/b[height<=\(height)]"
            args += ["-f", selector, "--merge-output-format", "mp4"]
            if includeSubtitles {
                // Creator-uploaded tracks only (never --write-auto-subs). Embedded via the bundled
                // ffmpeg (mov_text) and sidecars removed. live_chat is chat JSON, not a subtitle.
                args += ["--embed-subs", "--sub-langs", "all,-live_chat"]
            }
        case .video(let height):
            // Original-codec profile: normal for 1440p+, and the safe fallback when a lower
            // quality has no AVC1 offer. MKV preserves VP9/AV1 without the FFmpeg crash seen
            // while muxing those codecs to MP4. Exact-height tiers lead, then the closest lower.
            let selector = "bv[height=\(height)]+ba/b[height=\(height)]/bv[height<=\(height)]+ba/b[height<=\(height)]"
            args += [
                "-f", selector,
                "--merge-output-format", "mkv",
                // A progressive `b` fallback is not merged, so force its final container too.
                "--remux-video", "mkv",
            ]
            if includeSubtitles {
                args += ["--embed-subs", "--sub-langs", "all,-live_chat"]
            }
        case .maximumVideo:
            // Canonical best-video selection: `bv*` also covers sites whose highest offer is
            // already muxed. MKV safely carries the original codecs without a lossy transcode.
            args += [
                "-f", "bv*+ba/b",
                "--merge-output-format", "mkv",
                "--remux-video", "mkv",
            ]
            if includeSubtitles {
                args += ["--embed-subs", "--sub-langs", "all,-live_chat"]
            }
        case .audioMP3:
            // "ba/b": prefer audio-only; on muxed-only sites (e.g. archive.org) fall back
            // to the best muxed file and let -x extract its audio.
            args += ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "0"]
        case .audioM4A:
            // Prefer native M4A so the common path is a lossless remux. The explicit bitrate
            // only governs sites whose source audio must be converted.
            args += [
                "-f", "ba[ext=m4a]/ba/b",
                "-x", "--audio-format", "m4a", "--audio-quality", "192K",
            ]
        case .audioOpus:
            // libopus does not support FFmpeg's generic qscale. A bitrate is predictable for
            // fallback conversion; native Opus sources are extracted without re-encoding.
            args += [
                "-f", "ba[acodec^=opus]/ba/b",
                "-x", "--audio-format", "opus", "--audio-quality", "160K",
            ]
        }

        args.append(url)
        return args
    }
}
