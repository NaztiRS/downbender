import Testing
import Foundation
@testable import DownbenderCore

@Test func formatParserBuildsQualityListCappedAt1080() throws {
    let url = Bundle.module.url(forResource: "probe", withExtension: "json", subdirectory: "Fixtures")!
    let data = try Data(contentsOf: url)
    let result = try FormatParser.parse(data)

    #expect(result.videoID == "abc123")
    #expect(result.title == "Test video")
    // The fixture carries 2160p/1440p, but the panel is capped at <=1080 by user decision (YouTube does not always serve >1080).
    #expect(result.availableFormats == [
        .video(height: 1080),
        .video(height: 720),
        .video(height: 360),
        .video(height: 144),
        .audioMP3,
    ])
    #expect(result.thumbnailURL?.host == "i.ytimg.com")
}

@Test func formatParserComputesApproxSizePerQuality() throws {
    let url = Bundle.module.url(forResource: "probe", withExtension: "json", subdirectory: "Fixtures")!
    let data = try Data(contentsOf: url)
    let result = try FormatParser.parse(data)

    // 1080p: the HLS candidate (299, higher tbr) must be discarded by -S proto; 248 wins
    // (highest tbr among the non-HLS) + audio 140. 48_000_000 + 3_400_000.
    #expect(result.approxSizeBytes[.video(height: 1080)] == 51_400_000)

    // 720p: format 22 is muxed, but the real selector `bv*[height=H]+ba` STILL downloads
    // separate audio and merges, so the honest size always adds the audio (140). 30M + 3.4M.
    #expect(result.approxSizeBytes[.video(height: 720)] == 33_400_000)

    // 144p: format 160 only carries filesize_approx, which must serve as a fallback, + audio (140).
    #expect(result.approxSizeBytes[.video(height: 144)] == 8_400_000)

    // 360p: format 134 carries neither filesize nor filesize_approx -> a size must never
    // be invented; the quality is listed but gets no entry.
    #expect(result.approxSizeBytes[.video(height: 360)] == nil)

    // >1080 is out of the panel by user decision, even though the fixture carries those formats.
    #expect(result.approxSizeBytes[.video(height: 1440)] == nil)
    #expect(result.approxSizeBytes[.video(height: 2160)] == nil)

    // audioMP3 never carries a size: the conversion changes the real weight.
    #expect(result.approxSizeBytes[.audioMP3] == nil)
}

// MARK: - Sites with unknown codecs (e.g. archive.org: height present, vcodec/acodec null)

/// yt-dlp semantics: `vcodec: null` means UNKNOWN codec, `"none"` means definitely no video track.
@Test func formatParserOffersFormatsWhenCodecsAreUnknown() throws {
    let json = """
    {
      "id": "arch1",
      "title": "Public domain film",
      "formats": [
        {"format_id": "0", "ext": "ogv", "height": 300},
        {"format_id": "1", "ext": "mp4", "height": 360},
        {"format_id": "2", "ext": "avi", "height": 720}
      ]
    }
    """
    let result = try FormatParser.parse(Data(json.utf8))

    #expect(result.availableFormats == [
        .video(height: 720),
        .video(height: 360),
        .video(height: 300),
        .audioMP3,
    ])
}

@Test func formatParserStillExcludesExplicitNoneCodecs() throws {
    let json = """
    {
      "id": "x1",
      "title": "Video-only formats",
      "formats": [
        {"format_id": "v", "ext": "mp4", "height": 480, "vcodec": "avc1.64001F", "acodec": "none"},
        {"format_id": "a", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2"}
      ]
    }
    """
    let result = try FormatParser.parse(Data(json.utf8))

    #expect(result.availableFormats.contains(.video(height: 480)))
    #expect(!result.availableFormats.contains(.video(height: 0)))
    #expect(result.availableFormats.contains(.audioMP3))
}

@Test func formatParserUsesVideoSizeAloneWhenNoSeparateAudioExists() throws {
    let json = """
    {
      "id": "arch2",
      "title": "Muxed only",
      "formats": [
        {"format_id": "1", "ext": "mp4", "height": 360, "filesize": 1000000}
      ]
    }
    """
    let result = try FormatParser.parse(Data(json.utf8))

    #expect(result.approxSizeBytes[.video(height: 360)] == 1_000_000)
}

// MARK: - Subtitles (creator-uploaded only)

@Test func formatParserExtractsRealSubtitleLanguagesSorted() throws {
    let url = Bundle.module.url(forResource: "probe", withExtension: "json", subdirectory: "Fixtures")!
    let result = try FormatParser.parse(try Data(contentsOf: url))
    // live_chat is chat JSON, not a subtitle; automatic_captions ("fr") are excluded by design.
    #expect(result.subtitleLanguages == ["en", "es"])
}

@Test func formatParserReturnsEmptyLanguagesWithoutSubtitlesField() throws {
    let json = """
    {"id": "x1", "title": "No subs", "formats": [{"format_id": "1", "height": 360, "vcodec": "avc1", "acodec": "mp4a"}]}
    """
    let result = try FormatParser.parse(Data(json.utf8))
    #expect(result.subtitleLanguages == [])
}

@Test func formatParserIgnoresAutomaticCaptionsOnly() throws {
    let json = """
    {"id": "x2", "title": "Auto only", "formats": [{"format_id": "1", "height": 360, "vcodec": "avc1", "acodec": "mp4a"}], "subtitles": {}, "automatic_captions": {"en": [{"ext": "vtt"}]}}
    """
    let result = try FormatParser.parse(Data(json.utf8))
    #expect(result.subtitleLanguages == [])
}

@Test func approxDownloadSizeFallsBackToClosestLowerQuality() throws {
    let url = Bundle.module.url(forResource: "probe", withExtension: "json", subdirectory: "Fixtures")!
    let result = try FormatParser.parse(try Data(contentsOf: url))
    // 2160p is not offered (1080 cap), so the request lands on the best listed at or below it.
    #expect(result.approxDownloadSize(for: .video(height: 2160)) == 51_400_000)
    #expect(result.approxDownloadSize(for: .video(height: 720)) == 33_400_000)
    // 360p exists but carries no size: never invented.
    #expect(result.approxDownloadSize(for: .video(height: 360)) == nil)
    #expect(result.approxDownloadSize(for: .audioMP3) == nil)
}

// MARK: - Playlists

@Test func parseOutcomeDetectsFlatPlaylist() throws {
    let url = Bundle.module.url(forResource: "playlist", withExtension: "json", subdirectory: "Fixtures")!
    let outcome = try FormatParser.parseOutcome(try Data(contentsOf: url))
    guard case .playlist(let playlist) = outcome else {
        Issue.record("expected .playlist, got \(outcome)")
        return
    }
    #expect(playlist.title == "Test playlist")
    // The entry with neither url nor a YouTube id cannot be downloaded: dropped.
    #expect(playlist.entries.count == 3)

    #expect(playlist.entries[0].url == "https://www.youtube.com/watch?v=vid1")
    #expect(playlist.entries[0].title == "First video")
    #expect(playlist.entries[0].thumbnailURL?.absoluteString == "https://i.ytimg.com/vi/vid1/hqdefault.jpg")
    #expect(playlist.entries[0].durationSeconds == 100.0)

    // No url in the entry: rebuilt from the YouTube id; thumbnail likewise.
    #expect(playlist.entries[1].url == "https://www.youtube.com/watch?v=vid2")
    #expect(playlist.entries[1].thumbnailURL?.absoluteString == "https://i.ytimg.com/vi/vid2/hqdefault.jpg")

    // Null title (deleted/private): the url beats an empty card.
    #expect(playlist.entries[2].title == "https://www.youtube.com/watch?v=vid3")
}

@Test func parseOutcomeReturnsVideoForSingleVideoJSON() throws {
    let url = Bundle.module.url(forResource: "probe", withExtension: "json", subdirectory: "Fixtures")!
    let outcome = try FormatParser.parseOutcome(try Data(contentsOf: url))
    guard case .video(let result) = outcome else {
        Issue.record("expected .video, got \(outcome)")
        return
    }
    #expect(result.title == "Test video")
}

// MARK: - Extractor confidence

@Test func parseFlagsGenericExtractorAsLowConfidence() throws {
    let json = #"""
    {"id":"x","title":"Raw","extractor":"generic","formats":[{"format_id":"0","height":720,"vcodec":"avc1","acodec":"mp4a"}]}
    """#
    let result = try FormatParser.parse(Data(json.utf8))
    #expect(result.extractor == "generic")
    #expect(result.isGeneric)
}

@Test func parseKeepsSpecificExtractorAsConfident() throws {
    let json = #"""
    {"id":"x","title":"YT","extractor":"youtube","formats":[{"format_id":"0","height":720,"vcodec":"avc1","acodec":"mp4a"}]}
    """#
    let result = try FormatParser.parse(Data(json.utf8))
    #expect(result.extractor == "youtube")
    #expect(!result.isGeneric)
}
