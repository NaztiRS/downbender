import Foundation

/// Browser catalog shared by cookie import and the browser-extension installer.
/// Raw values are the exact names expected by yt-dlp's `--cookies-from-browser`.
public enum BrowserKind: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case chrome
    case brave
    case edge
    case chromium
    case safari
    case firefox

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chrome: "Google Chrome"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .chromium: "Chromium"
        case .safari: "Safari"
        case .firefox: "Firefox"
        }
    }

    public var applicationBundleIdentifier: String {
        switch self {
        case .chrome: "com.google.Chrome"
        case .brave: "com.brave.Browser"
        case .edge: "com.microsoft.edgemac"
        case .chromium: "org.chromium.Chromium"
        case .safari: "com.apple.Safari"
        case .firefox: "org.mozilla.firefox"
        }
    }

    /// Safari and Firefox can provide cookies, but the bundled extension is Chromium-only.
    public var chromiumBrowser: ChromiumBrowser? {
        ChromiumBrowser(rawValue: rawValue)
    }
}

/// Testable result of Launch Services browser detection. Detection never selects a
/// cookie source automatically; it only limits the choices shown to installed apps.
public struct BrowserInventory: Equatable, Sendable {
    public let installed: Set<BrowserKind>

    public init(installed: Set<BrowserKind>) {
        self.installed = installed
    }

    public static func detect(isBundleInstalled: (String) -> Bool) -> BrowserInventory {
        BrowserInventory(installed: Set(BrowserKind.allCases.filter {
            isBundleInstalled($0.applicationBundleIdentifier)
        }))
    }

    public var cookieBrowsers: [BrowserKind] {
        BrowserKind.allCases.filter(installed.contains)
    }

    public var chromiumBrowsers: [ChromiumBrowser] {
        cookieBrowsers.compactMap(\.chromiumBrowser)
    }

    /// Restores a persisted cookie source only while its application is still installed.
    public func installedCookieBrowser(rawValue: String?) -> BrowserKind? {
        guard let rawValue,
              let browser = BrowserKind(rawValue: rawValue),
              installed.contains(browser)
        else { return nil }
        return browser
    }
}
