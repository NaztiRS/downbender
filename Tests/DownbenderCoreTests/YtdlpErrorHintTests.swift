import Testing
@testable import DownbenderCore

@Test func friendlyMapsYouTubeBotGateToCookiesHint() {
    let raw = "ERROR: [youtube] jVRcI47Hhp0: Sign in to confirm you're not a bot. Use --cookies-from-browser or --cookies for the authentication."
    let hint = YtdlpErrorHint.friendly(raw)
    #expect(hint?.contains("Browser cookies") == true)
}

@Test func friendlyReturnsNilForUnrelatedErrors() {
    #expect(YtdlpErrorHint.friendly("ERROR: Unsupported URL: https://example.com/") == nil)
    #expect(YtdlpErrorHint.friendly("") == nil)
}
