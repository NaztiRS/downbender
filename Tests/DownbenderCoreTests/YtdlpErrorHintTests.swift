import Testing
@testable import DownbenderCore

@Test func friendlyMapsYouTubeBotGateToCookiesHint() {
    let raw = "ERROR: [youtube] jVRcI47Hhp0: Sign in to confirm you're not a bot. Use --cookies-from-browser or --cookies for the authentication."
    let hint = YtdlpErrorHint.friendly(raw)
    #expect(hint?.contains("Browser cookies") == true)
    #expect(hint?.contains("Open Settings") == false)
}

@Test func botGateHintCarriesAnOpenSettingsAction() {
    let raw = "ERROR: Sign in to confirm you're not a bot. Use --cookies-from-browser."
    let hint = YtdlpErrorHint.hint(for: raw)
    #expect(hint?.suggestedAction == .openSettings)
    #expect(hint?.message.contains("Browser cookies") == true)
}

@Test func friendlyReturnsNilForUnrelatedErrors() {
    #expect(YtdlpErrorHint.friendly("ERROR: Unsupported URL: https://example.com/") == nil)
    #expect(YtdlpErrorHint.friendly("") == nil)
    #expect(YtdlpErrorHint.hint(for: "ERROR: Unsupported URL: https://example.com/") == nil)
}

@Test func friendlyMapsDNSResolutionFailureToNetworkHint() {
    let raw = "ERROR: [download] Got error: HTTPSConnection(host='rr5---sn-hp57ynsl.googlevideo.com', port=443): Failed to resolve 'rr5---sn-hp57ynsl.googlevideo.com' ([Errno 8] nodename nor servname provided, or not known). Giving up after 10 retries"
    let hint = YtdlpErrorHint.friendly(raw)
    let lower = hint?.lowercased()
    #expect(lower?.contains("connection") == true)
    #expect(lower?.contains("network") == true)
    #expect(YtdlpErrorHint.hint(for: raw)?.suggestedAction == nil)
}

@Test func latestFixesAreOfferedOnlyForLikelyExtractorFailures() {
    #expect(YtdlpErrorHint.shouldOfferLatestFixes(
        for: "ERROR: [youtube] Unable to extract player response"
    ))
    #expect(!YtdlpErrorHint.shouldOfferLatestFixes(
        for: "ERROR: Sign in to confirm you're not a bot. Use --cookies-from-browser."
    ))
    #expect(!YtdlpErrorHint.shouldOfferLatestFixes(
        for: "ERROR: Failed to resolve googlevideo.com"
    ))
    #expect(!YtdlpErrorHint.shouldOfferLatestFixes(
        for: "ERROR: No space left on device"
    ))
}
