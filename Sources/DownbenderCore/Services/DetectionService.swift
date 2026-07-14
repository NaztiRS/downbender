import Foundation

/// How a submitted URL should be handled. The clipboard trigger stays in MediaURL; this is the
/// front-door router for BOTH manual paste and clipboard, deciding by file extension only —
/// never by network. `.probe` means "ask yt-dlp" (today's default path).
public enum IntakeRoute: Equatable {
    case directFile   // clearly a downloadable file (.zip/.pdf/.dmg/image/…)
    case mediaFile    // a raw video/audio file (.mp4/.mp3/…): let the user pick process-or-raw
    case probe        // no clear extension: run the yt-dlp probe as today
}

public enum DetectionService {
    static let mediaExtensions: Set<String> = [
        "mp4", "mkv", "webm", "mov", "m4v", "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus",
    ]
    static let directExtensions: Set<String> = [
        "zip", "pdf", "dmg", "pkg", "img", "iso", "gz", "tgz", "bz2", "xz", "7z", "rar",
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg",
        "exe", "msi", "deb", "rpm", "apk", "app",
        "txt", "csv", "json", "xml", "epub", "mobi",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx",
    ]

    public static func classify(_ url: String) -> IntakeRoute {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed) else { return .probe }
        let ext = parsed.pathExtension.lowercased()
        guard !ext.isEmpty else { return .probe }
        if mediaExtensions.contains(ext) { return .mediaFile }
        if directExtensions.contains(ext) { return .directFile }
        return .probe
    }
}
