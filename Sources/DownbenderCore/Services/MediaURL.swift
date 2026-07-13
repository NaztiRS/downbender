import Foundation

/// Detects a downloadable video URL in text — only the trigger for the clipboard prompt;
/// yt-dlp's probe is the real judge, and manual paste is never filtered here.
public enum MediaURL {
    static let youtubeHosts: Set<String> = ["youtu.be", "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"]

    static let knownVideoHosts: Set<String> = [
        "vimeo.com", "www.vimeo.com", "player.vimeo.com",
        "x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com",
        "tiktok.com", "www.tiktok.com", "vm.tiktok.com",
        "twitch.tv", "www.twitch.tv", "clips.twitch.tv",
        "instagram.com", "www.instagram.com",
        "dailymotion.com", "www.dailymotion.com", "dai.ly",
        "reddit.com", "www.reddit.com", "old.reddit.com",
        "streamable.com", "www.streamable.com",
    ]

    /// A watch link that ALSO carries a playlist (`v=` + `list=`): the UI asks which one the user meant.
    public static func pointsToVideoInPlaylist(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased(),
              youtubeHosts.contains(host),
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return false }
        func has(_ name: String) -> Bool {
            query.contains { $0.name == name && $0.value?.isEmpty == false }
        }
        let isVideo = host == "youtu.be" ? url.path.count > 1 : has("v")
        return isVideo && has("list")
    }

    public static func detect(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return nil }

        if youtubeHosts.contains(host) {
            if host == "youtu.be" {
                return url.path.count > 1 ? trimmed : nil
            }
            if url.path == "/watch" {
                let videoID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "v" })?.value
                return (videoID?.isEmpty == false) ? trimmed : nil
            }
            if url.path.hasPrefix("/shorts/"), url.path.count > "/shorts/".count {
                return trimmed
            }
            return nil
        }

        if knownVideoHosts.contains(host), url.path.count > 1 {
            return trimmed
        }
        return nil
    }
}
