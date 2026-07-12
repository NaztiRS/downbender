import Testing
import Foundation
@testable import DownbenderCore

private func args(
    _ format: DownloadFormat,
    denoURL: URL? = nil,
    cookiesBrowser: String? = nil,
    includeSubtitles: Bool = false,
    useTVClient: Bool = false
) -> [String] {
    DownloadArgsBuilder.arguments(
        url: "https://youtu.be/abc123",
        format: format,
        destination: URL(fileURLWithPath: "/tmp/dest"),
        tmpDirectory: URL(fileURLWithPath: "/tmp/work"),
        ffmpegDirectory: URL(fileURLWithPath: "/app/ffmpeg-dir"),
        denoURL: denoURL,
        cookiesBrowser: cookiesBrowser,
        includeSubtitles: includeSubtitles,
        useTVClient: useTVClient
    )
}

// Also guards the builder's global arguments: no-playlist, ffmpeg location, destinations, output template, merge format.
@Test func videoDefaultUsesBestUpTo1080() {
    let a = args(.video(height: 1080))
    #expect(a.contains("--no-config"))
    #expect(a.contains("-f"))
    // The bundled ffmpeg CRASHES (SIGSEGV) muxing VP9/AV1 + audio into mp4, so merges are restricted to avc1 + m4a, with a progressive-mp4 fallback.
    #expect(a.contains("bv*[height=1080][vcodec^=avc1]+ba[ext=m4a]/bv*[height<=1080][vcodec^=avc1]+ba[ext=m4a]/b[height<=1080][ext=mp4]/b[height<=1080]"))
    #expect(a.contains("--merge-output-format"))
    #expect(a.last == "https://youtu.be/abc123")

    guard let sortFlagIndex = a.firstIndex(of: "-S") else {
        Issue.record("missing -S")
        return
    }
    #expect(a[sortFlagIndex + 1] == "res,fps,proto,lang,br")

    #expect(a.contains("--no-playlist"))

    guard let ffmpegFlagIndex = a.firstIndex(of: "--ffmpeg-location") else {
        Issue.record("missing --ffmpeg-location")
        return
    }
    #expect(a[ffmpegFlagIndex + 1] == "/app/ffmpeg-dir")

    let destinationValues = a.indices
        .filter { a[$0] == "-P" }
        .map { a[$0 + 1] }
    #expect(destinationValues.contains("/tmp/dest"))
    #expect(destinationValues.contains("temp:/tmp/work"))

    guard let outputFlagIndex = a.firstIndex(of: "-o") else {
        Issue.record("missing -o")
        return
    }
    #expect(a[outputFlagIndex + 1] == "%(title)s.%(ext)s")

    guard let mergeFlagIndex = a.firstIndex(of: "--merge-output-format") else {
        Issue.record("missing --merge-output-format")
        return
    }
    #expect(a[mergeFlagIndex + 1] == "mp4")
}

// --print implies --quiet in yt-dlp; --progress restores DBPROG, and after_move does not imply --simulate so DBPATH still arrives.
@Test func printsDeliveredPathAndKeepsProgress() {
    let a = args(.video(height: 1080))
    #expect(a.contains("--progress"))

    guard let printFlagIndex = a.firstIndex(of: "--print") else {
        Issue.record("missing --print")
        return
    }
    #expect(a[printFlagIndex + 1] == "after_move:DBPATH %(filepath)s")
}

// --print implies quiet: without --no-quiet the "[download] Destination:" and "[Merger]" lines disappear (verified against the real binary).
@Test func includesNoQuietSoDestinationAndMergerLinesAppear() {
    #expect(args(.video(height: 1080)).contains("--no-quiet"))
    #expect(args(.audioMP3).contains("--no-quiet"))
}

// Counterpart of the ProgressParserTests round-trip: without this assert, dropping the flag would leave the suite green and the bar frozen at 0%.
@Test func passesProgressTemplateToYtdlp() {
    let a = args(.video(height: 1080))
    guard let i = a.firstIndex(of: "--progress-template") else {
        Issue.record("missing --progress-template")
        return
    }
    #expect(a[i + 1] == DownloadArgsBuilder.progressTemplate)
}

// yt-dlp's internal retries: first line of defense against transient errors, before the coordinator's full retry.
@Test func includesInternalRetries() {
    let a = args(.video(height: 1080))

    guard let retriesIndex = a.firstIndex(of: "--retries") else {
        Issue.record("missing --retries")
        return
    }
    #expect(a[retriesIndex + 1] == "10")

    guard let fragmentRetriesIndex = a.firstIndex(of: "--fragment-retries") else {
        Issue.record("missing --fragment-retries")
        return
    }
    #expect(a[fragmentRetriesIndex + 1] == "10")
}

// Last resort against a persistent 403: the TV client sits outside YouTube's PO-token shielding.
@Test func includesTVClientExtractorArgsWhenRequested() {
    let a = args(.video(height: 1080), useTVClient: true)

    guard let extractorIndex = a.firstIndex(of: "--extractor-args") else {
        Issue.record("missing --extractor-args")
        return
    }
    #expect(a[extractorIndex + 1] == "youtube:player_client=tv")
    #expect(a.last == "https://youtu.be/abc123")
}

@Test func omitsTVClientExtractorArgsByDefault() {
    let a = args(.video(height: 1080))
    #expect(!a.contains("--extractor-args"))
    #expect(!a.contains("youtube:player_client=tv"))
}

// Anti-crash guarantee: every merge tier must require avc1; a bare "bv*+ba" could pick VP9/AV1 and blow up the bundled ffmpeg.
@Test func videoSelectorNeverMergesNonAvc1() {
    let a = args(.video(height: 720))
    guard let selectorIndex = a.firstIndex(of: "-f") else {
        Issue.record("missing -f")
        return
    }
    let selector = a[selectorIndex + 1]
    for tier in selector.split(separator: "/") where tier.contains("+") {
        #expect(tier.contains("[vcodec^=avc1]"), "merge tier without avc1: \(tier)")
        #expect(tier.contains("+ba[ext=m4a]"), "merge tier without m4a audio: \(tier)")
    }
}

@Test func audioExtractsMP3() {
    let a = args(.audioMP3)
    #expect(a.contains("-x"))
    #expect(a.contains("mp3"))
    #expect(a.contains("--audio-format"))

    guard let sortFlagIndex = a.firstIndex(of: "-S") else {
        Issue.record("missing -S")
        return
    }
    #expect(a[sortFlagIndex + 1] == "res,fps,proto,lang,br")
}

@Test func includesDenoRuntimeAndCookiesFlagsWhenProvided() {
    let a = args(
        .video(height: 1080),
        denoURL: URL(fileURLWithPath: "/app/deno"),
        cookiesBrowser: "chrome"
    )

    guard let runtimeIndex = a.firstIndex(of: "--js-runtimes") else {
        Issue.record("missing --js-runtimes")
        return
    }
    #expect(a[runtimeIndex + 1] == "deno:/app/deno")

    guard let cookiesIndex = a.firstIndex(of: "--cookies-from-browser") else {
        Issue.record("missing --cookies-from-browser")
        return
    }
    #expect(a[cookiesIndex + 1] == "chrome")

    #expect(a.last == "https://youtu.be/abc123")
}

@Test func omitsDenoRuntimeAndCookiesFlagsWhenNotProvided() {
    let a = args(.video(height: 1080))
    #expect(!a.contains("--js-runtimes"))
    #expect(!a.contains("--cookies-from-browser"))
}

/// Sites without a separate audio-only format (e.g. archive.org): `ba/b` falls back to the best muxed file.
@Test func mp3SelectorFallsBackToMuxedFormats() {
    let args = DownloadArgsBuilder.arguments(
        url: "https://archive.org/details/x",
        format: .audioMP3,
        destination: URL(fileURLWithPath: "/tmp/dest"),
        tmpDirectory: URL(fileURLWithPath: "/tmp/work"),
        ffmpegDirectory: URL(fileURLWithPath: "/ff")
    )
    guard let fIndex = args.firstIndex(of: "-f") else {
        Issue.record("missing -f")
        return
    }
    #expect(args[fIndex + 1] == "ba/b")
}

// MARK: - Subtitles

@Test func videoWithSubtitlesEmbedsRealTracksOnly() {
    let a = args(.video(height: 1080), includeSubtitles: true)
    #expect(a.contains("--embed-subs"))
    guard let langsFlagIndex = a.firstIndex(of: "--sub-langs") else {
        Issue.record("missing --sub-langs")
        return
    }
    #expect(a[langsFlagIndex + 1] == "all,-live_chat")
    // No sidecars and no auto-captions, by design.
    #expect(!a.contains("--write-subs"))
    #expect(!a.contains("--write-auto-subs"))
}

@Test func subtitleFlagsAbsentByDefaultAndForMP3() {
    #expect(!args(.video(height: 1080)).contains("--embed-subs"))
    let mp3 = args(.audioMP3, includeSubtitles: true)
    #expect(!mp3.contains("--embed-subs"))
    #expect(!mp3.contains("--sub-langs"))
}
