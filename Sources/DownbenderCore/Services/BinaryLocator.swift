import Foundation

public enum BinaryLocator {
    public static func resolveYtdlp(updated: URL, bundled: URL?, fileExists: (URL) -> Bool) -> URL? {
        if fileExists(updated) { return updated }
        return bundled
    }
}

public struct BundledBinaries: Sendable {
    public let ytdlp: URL
    public let ffmpegDirectory: URL
    public let deno: URL?

    public static func locate(
        bundle: Bundle = .main,
        appSupportDirectory: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> BundledBinaries? {
        let bundledYtdlp = bundle.url(forResource: "yt-dlp_macos", withExtension: nil)
        let updated = appSupportDirectory.appendingPathComponent("yt-dlp_macos")
        guard let ytdlp = BinaryLocator.resolveYtdlp(updated: updated, bundled: bundledYtdlp, fileExists: fileExists) else { return nil }
        guard let ffmpeg = bundle.url(forResource: "ffmpeg", withExtension: nil) else { return nil }
        // deno is optional: if it isn't bundled, the app keeps working (degraded).
        let deno = bundle.url(forResource: "deno", withExtension: nil)
        return BundledBinaries(ytdlp: ytdlp, ffmpegDirectory: ffmpeg.deletingLastPathComponent(), deno: deno)
    }
}
