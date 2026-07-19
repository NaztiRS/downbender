import Foundation

/// JSON sent by the Chrome extension to Downbender's native-messaging host.
public struct BrowserExtensionRequest: Codable, Equatable, Sendable {
    public let command: String
    public let url: String?
    public let source: String?
    public let title: String?
    public let pageURL: String?
    public let mediaURL: String?

    public init(
        command: String = "enqueue",
        url: String? = nil,
        source: String? = nil,
        title: String? = nil,
        pageURL: String? = nil,
        mediaURL: String? = nil
    ) {
        self.command = command
        self.url = url
        self.source = source
        self.title = title
        self.pageURL = pageURL
        self.mediaURL = mediaURL
    }
}

/// JSON returned by the native host. Keeping the response tiny also keeps the extension UI fast.
public struct BrowserExtensionResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let message: String?

    public init(ok: Bool, message: String? = nil) {
        self.ok = ok
        self.message = message
    }
}

/// Validation and deep-link conversion shared by the app and its native-messaging helper.
public enum BrowserBridge {
    public static let deepLinkScheme = "downbender"
    public static let deepLinkHost = "add"
    public static let nativeHostName = "com.naztirs.downbender"
    public static let chromeExtensionID = "bfcndjoodnplbimoicmombomihhbjedm"

    private static let maximumURLLength = 32_768

    public static func validatedWebURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumURLLength,
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil
        else { return nil }
        return url
    }

    /// Resolves extension requests defensively. An overlay drawn over one playing video must
    /// never be allowed to enqueue an adjacent YouTube Mix or playlist.
    public static func downloadURL(for request: BrowserExtensionRequest) -> URL? {
        guard let value = request.url, let url = validatedWebURL(value) else { return nil }
        guard isYouTube(url) else { return url }

        if let singleVideo = youtubeSingleVideoURL(from: url) { return singleVideo }
        return request.source == "active-video-overlay" ? nil : url
    }

    private static func isYouTube(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    private static func youtubeSingleVideoURL(from url: URL) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }
        let videoID: String?
        let outputPath: String

        if host == "youtu.be" {
            videoID = url.pathComponents.dropFirst().first
            outputPath = "/watch"
        } else if url.path == "/watch" {
            videoID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value
            outputPath = "/watch"
        } else {
            let components = url.pathComponents.filter { $0 != "/" }
            guard components.count >= 2, components[0] == "shorts" || components[0] == "live" else {
                return nil
            }
            videoID = components[1]
            outputPath = "/\(components[0])/\(components[1])"
        }

        guard let videoID, !videoID.isEmpty else { return nil }
        var output = URLComponents()
        output.scheme = "https"
        output.host = "www.youtube.com"
        output.path = outputPath
        if outputPath == "/watch" {
            output.queryItems = [URLQueryItem(name: "v", value: videoID)]
        }
        return output.url
    }

    public static func deepLink(for webURL: URL) -> URL? {
        guard let validated = validatedWebURL(webURL.absoluteString) else { return nil }
        var components = URLComponents()
        components.scheme = deepLinkScheme
        components.host = deepLinkHost
        components.queryItems = [URLQueryItem(name: "url", value: validated.absoluteString)]
        return components.url
    }

    public static func webURL(from deepLink: URL) -> URL? {
        guard deepLink.scheme?.lowercased() == deepLinkScheme,
              deepLink.host?.lowercased() == deepLinkHost,
              let components = URLComponents(url: deepLink, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "url" })?.value
        else { return nil }
        return validatedWebURL(value)
    }
}
