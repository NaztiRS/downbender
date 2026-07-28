import Testing
@testable import DownbenderCore

@Test func browserCatalogKeepsDisplayNamesBundleIDsAndCookieArgumentsTogether() {
    let expected: [BrowserKind: (name: String, bundleID: String)] = [
        .chrome: ("Google Chrome", "com.google.Chrome"),
        .brave: ("Brave", "com.brave.Browser"),
        .edge: ("Microsoft Edge", "com.microsoft.edgemac"),
        .chromium: ("Chromium", "org.chromium.Chromium"),
        .safari: ("Safari", "com.apple.Safari"),
        .firefox: ("Firefox", "org.mozilla.firefox"),
    ]

    #expect(BrowserKind.allCases.count == expected.count)
    for browser in BrowserKind.allCases {
        #expect(browser.displayName == expected[browser]?.name)
        #expect(browser.applicationBundleIdentifier == expected[browser]?.bundleID)
        #expect(BrowserKind(rawValue: browser.rawValue) == browser)
    }
    #expect(BrowserKind(rawValue: "Google Chrome") == nil)
}

@Test func browserInventoryAutodetectsCookieSourcesAndKeepsExtensionSubsetTyped() {
    let installedBundleIDs: Set<String> = [
        BrowserKind.edge.applicationBundleIdentifier,
        BrowserKind.safari.applicationBundleIdentifier,
        BrowserKind.firefox.applicationBundleIdentifier,
    ]

    let inventory = BrowserInventory.detect {
        installedBundleIDs.contains($0)
    }

    #expect(inventory.cookieBrowsers == [.edge, .safari, .firefox])
    #expect(inventory.chromiumBrowsers == [.edge])
    #expect(inventory.installedCookieBrowser(rawValue: "safari") == .safari)
    #expect(inventory.installedCookieBrowser(rawValue: "chrome") == nil)
    #expect(inventory.installedCookieBrowser(rawValue: "unknown") == nil)
    #expect(inventory.installedCookieBrowser(rawValue: nil) == nil)
}

@Test func chromiumBrowsersReuseTheSharedCatalog() {
    #expect(ChromiumBrowser.allCases.map(\.browserKind) == [.chrome, .brave, .edge, .chromium])
    #expect(BrowserKind.safari.chromiumBrowser == nil)
    #expect(BrowserKind.firefox.chromiumBrowser == nil)
}

@Test func everyCatalogBrowserProducesItsCanonicalYTDLPCookieArgument() {
    for browser in BrowserKind.allCases {
        let arguments = DownloadArgsBuilder.baseArgs(
            denoURL: nil,
            cookiesBrowser: browser.rawValue
        )
        guard let optionIndex = arguments.firstIndex(of: "--cookies-from-browser") else {
            Issue.record("missing cookie option for \(browser)")
            continue
        }
        #expect(arguments[optionIndex + 1] == browser.rawValue)
    }
}
