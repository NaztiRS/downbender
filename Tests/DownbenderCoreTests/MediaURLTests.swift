import Testing
@testable import DownbenderCore

@Test func detectsWatchShortsAndYoutuBe() {
    #expect(MediaURL.detect(in: "https://www.youtube.com/watch?v=abc123") == "https://www.youtube.com/watch?v=abc123")
    #expect(MediaURL.detect(in: "  https://youtu.be/abc123  ") == "https://youtu.be/abc123")
    #expect(MediaURL.detect(in: "https://youtube.com/shorts/xyz") == "https://youtube.com/shorts/xyz")
}

@Test func rejectsNonVideoAndOtherSites() {
    #expect(MediaURL.detect(in: "https://www.youtube.com/") == nil)
    #expect(MediaURL.detect(in: "https://google.com/watch?v=abc") == nil)
    #expect(MediaURL.detect(in: "https://www.youtube.com/watch?v=") == nil)
    #expect(MediaURL.detect(in: "hola que tal") == nil)
}

// MARK: - Non-YouTube known video hosts

@Test func detectsVimeoURL() {
    #expect(MediaURL.detect(in: "https://vimeo.com/123456789") == "https://vimeo.com/123456789")
}

@Test func detectsXStatusURL() {
    let url = "https://x.com/user/status/1234567890"
    #expect(MediaURL.detect(in: url) == url)
}

@Test func detectsTikTokURL() {
    let url = "https://www.tiktok.com/@user/video/1234567890"
    #expect(MediaURL.detect(in: url) == url)
}

@Test func ignoresUnknownHosts() {
    #expect(MediaURL.detect(in: "https://example.com/watch?v=abc") == nil)
    #expect(MediaURL.detect(in: "https://google.com/") == nil)
}

@Test func ignoresKnownHostWithEmptyPath() {
    #expect(MediaURL.detect(in: "https://vimeo.com/") == nil)
}

// MARK: - Video-inside-playlist links

@Test func flagsWatchURLsCarryingAPlaylist() {
    #expect(MediaURL.pointsToVideoInPlaylist("https://www.youtube.com/watch?v=wGWMGJw6cV8&list=RDGMEMgGOgHdkrBSNHvacS9Sp8bg&start_radio=1&rv=hrgsMWRBKa8"))
    #expect(MediaURL.pointsToVideoInPlaylist("https://youtu.be/abc123?list=PLx"))
}

@Test func plainVideosAndPurePlaylistsNeedNoScopeChoice() {
    #expect(!MediaURL.pointsToVideoInPlaylist("https://www.youtube.com/watch?v=abc123"))
    #expect(!MediaURL.pointsToVideoInPlaylist("https://www.youtube.com/playlist?list=PLx"))
    #expect(!MediaURL.pointsToVideoInPlaylist("https://www.youtube.com/watch?v=abc&list="))
    #expect(!MediaURL.pointsToVideoInPlaylist("hola que tal"))
}
