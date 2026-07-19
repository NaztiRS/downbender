import Foundation
import Testing
@testable import DownbenderCore

@Test func browserBridgeRoundTripsEncodedWebURL() throws {
    let source = try #require(URL(string: "https://www.youtube.com/watch?v=a_b-C&list=PL 1"))
    let deepLink = try #require(BrowserBridge.deepLink(for: source))

    #expect(deepLink.scheme == "downbender")
    #expect(deepLink.host == "add")
    #expect(BrowserBridge.webURL(from: deepLink)?.absoluteString == source.absoluteString)
}

@Test func browserBridgeRejectsUntrustedSchemesAndMalformedLinks() {
    #expect(BrowserBridge.validatedWebURL("javascript:alert(1)") == nil)
    #expect(BrowserBridge.validatedWebURL("file:///tmp/video.mp4") == nil)
    #expect(BrowserBridge.validatedWebURL("https:///missing-host") == nil)
    #expect(BrowserBridge.webURL(from: URL(string: "downbender://wrong?url=https://example.com")!) == nil)
}

@Test func browserMessagesEncodeTheExtensionContract() throws {
    let request = BrowserExtensionRequest(
        url: "https://youtu.be/abc",
        source: "active-video-overlay",
        title: "Video",
        pageURL: "https://youtube.com/",
        mediaURL: "blob:https://youtube.com/id"
    )
    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(BrowserExtensionRequest.self, from: data)

    #expect(decoded == request)
    #expect(decoded.command == "enqueue")
}

@Test func browserMessagesDecodeInstallationHandshakeWithoutURL() throws {
    let data = Data(#"{"command":"extension-installed"}"#.utf8)
    let decoded = try JSONDecoder().decode(BrowserExtensionRequest.self, from: data)

    #expect(decoded.command == "extension-installed")
    #expect(decoded.url == nil)
}

@Test func activeVideoRequestCanNeverBecomeAYouTubePlaylist() throws {
    let mix = BrowserExtensionRequest(
        url: "https://www.youtube.com/watch?v=oneVideo&list=RDoneVideo&index=7",
        source: "active-video-overlay"
    )
    let explicitPlaylist = BrowserExtensionRequest(
        url: "https://www.youtube.com/playlist?list=PLhuge",
        source: "active-video-overlay"
    )

    #expect(BrowserBridge.downloadURL(for: mix)?.absoluteString == "https://www.youtube.com/watch?v=oneVideo")
    #expect(BrowserBridge.downloadURL(for: explicitPlaylist) == nil)
}

@Test func explicitContextMenuPlaylistRemainsAllowed() {
    let request = BrowserExtensionRequest(
        url: "https://www.youtube.com/playlist?list=PLintentional",
        source: "context-page"
    )

    #expect(BrowserBridge.downloadURL(for: request)?.absoluteString == request.url)
}
