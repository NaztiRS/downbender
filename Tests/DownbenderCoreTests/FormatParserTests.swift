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
