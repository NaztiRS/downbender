import Foundation

/// Chromium browsers supported by the bundled extension on macOS.
public enum ChromiumBrowser: String, CaseIterable, Hashable, Sendable {
    case chrome
    case brave
    case edge
    case chromium

    public var browserKind: BrowserKind {
        switch self {
        case .chrome: .chrome
        case .brave: .brave
        case .edge: .edge
        case .chromium: .chromium
        }
    }

    public var displayName: String {
        browserKind.displayName
    }

    public var applicationBundleIdentifier: String {
        browserKind.applicationBundleIdentifier
    }

    public var extensionsPage: String {
        switch self {
        case .brave: "brave://extensions/"
        case .edge: "edge://extensions/"
        case .chrome, .chromium: "chrome://extensions/"
        }
    }

    fileprivate var applicationSupportPath: String {
        switch self {
        case .chrome: "Library/Application Support/Google/Chrome"
        case .brave: "Library/Application Support/BraveSoftware/Brave-Browser"
        case .edge: "Library/Application Support/Microsoft Edge"
        case .chromium: "Library/Application Support/Chromium"
        }
    }
}

public enum ChromiumNativeMessagingError: LocalizedError, Equatable {
    case hostNotExecutable(URL)

    public var errorDescription: String? {
        switch self {
        case .hostNotExecutable(let url):
            "Downbender's browser helper is missing or not executable at \(url.path)."
        }
    }
}

/// Writes a browser-specific copy of Downbender's native-host manifest. Registering one browser
/// at a time keeps a damaged profile directory from disabling integration in every other browser.
public enum ChromiumNativeMessaging {
    public static func manifestURL(
        for browser: ChromiumBrowser,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(browser.applicationSupportPath, isDirectory: true)
            .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent("\(BrowserBridge.nativeHostName).json")
    }

    @discardableResult
    public static func installDownbenderHost(
        executable: URL,
        for browser: ChromiumBrowser,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard executable.isFileURL, fileManager.isExecutableFile(atPath: executable.path) else {
            throw ChromiumNativeMessagingError.hostNotExecutable(executable)
        }

        let manifest = NativeHostManifest(
            name: BrowserBridge.nativeHostName,
            description: "Send browser video links to Downbender",
            path: executable.path,
            type: "stdio",
            allowedOrigins: ["chrome-extension://\(BrowserBridge.chromeExtensionID)/"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)

        let destination = manifestURL(for: browser, homeDirectory: homeDirectory)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        return destination
    }
}

private struct NativeHostManifest: Encodable {
    let name: String
    let description: String
    let path: String
    let type: String
    let allowedOrigins: [String]

    private enum CodingKeys: String, CodingKey {
        case name, description, path, type
        case allowedOrigins = "allowed_origins"
    }
}
