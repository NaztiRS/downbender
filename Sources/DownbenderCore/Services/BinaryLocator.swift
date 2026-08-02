import Foundation

public enum BinaryLocator {
    public static let nightlyYtdlpFilename = "yt-dlp-nightly_macos"

    public static func nightlyYtdlpURL(appSupportDirectory: URL) -> URL {
        appSupportDirectory.appendingPathComponent(nightlyYtdlpFilename)
    }

    /// Resolves a requested engine without ever treating the retired Application Support
    /// `yt-dlp_macos` override as stable. A nightly is usable only when it both exists and is
    /// executable; every other case falls back to the known-good binary shipped in the app.
    public static func resolveYtdlp(
        channel: YtdlpEngineChannel,
        stable: URL,
        nightly: URL?,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) -> YtdlpEngineDescriptor {
        if channel == .nightly,
           let nightly,
           fileExists(nightly),
           isExecutable(nightly) {
            return YtdlpEngineDescriptor(channel: .nightly, executableURL: nightly)
        }
        return YtdlpEngineDescriptor(channel: .stable, executableURL: stable)
    }

    /// Source-compatible migration shim for callers that still pass the former stable override.
    /// App updates now own stable updates, so the bundled binary always wins.
    public static func resolveYtdlp(
        updated _: URL,
        bundled: URL?,
        fileExists _: (URL) -> Bool
    ) -> URL? {
        bundled
    }
}

public struct BundledBinaries: Sendable {
    /// The known-good stable yt-dlp shipped inside the application bundle.
    public let ytdlp: URL
    public let ffmpegDirectory: URL
    public let deno: URL?
    /// A usable nightly found at launch. `locate` leaves this nil unless the fixed Application
    /// Support path both exists and is executable.
    public let nightlyYtdlp: URL?

    /// Preserves the initializer used throughout the app and its tests.
    public init(ytdlp: URL, ffmpegDirectory: URL, deno: URL?) {
        self.init(ytdlp: ytdlp, ffmpegDirectory: ffmpegDirectory, deno: deno, nightlyYtdlp: nil)
    }

    public init(ytdlp: URL, ffmpegDirectory: URL, deno: URL?, nightlyYtdlp: URL?) {
        self.ytdlp = ytdlp
        self.ffmpegDirectory = ffmpegDirectory
        self.deno = deno
        self.nightlyYtdlp = nightlyYtdlp
    }

    public func resolveYtdlp(
        channel: YtdlpEngineChannel,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) -> YtdlpEngineDescriptor {
        BinaryLocator.resolveYtdlp(
            channel: channel,
            stable: ytdlp,
            nightly: nightlyYtdlp,
            fileExists: fileExists,
            isExecutable: isExecutable
        )
    }

    /// Stable yt-dlp ships as an already-extracted directory (`yt-dlp/yt-dlp` beside its
    /// `_internal` tree). The self-extracting single file wrote 104 fresh Mach-O files to a new
    /// temporary directory on every launch, and macOS rescans every unseen one through a single
    /// serial system service: measured 10 concurrent launches at 78 s, against 0.4 s for the
    /// directory layout whose inodes stay put. The flat `yt-dlp_macos` still resolves so an
    /// older Resources layout keeps working.
    private static func bundledYtdlpURL(in bundle: Bundle) -> URL? {
        bundle.url(forResource: "yt-dlp", withExtension: nil, subdirectory: "yt-dlp")
            ?? bundle.url(forResource: "yt-dlp_macos", withExtension: nil)
    }

    public static func locate(
        bundle: Bundle = .main,
        appSupportDirectory: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) -> BundledBinaries? {
        guard let bundledYtdlp = bundledYtdlpURL(in: bundle) else { return nil }
        guard let ffmpeg = bundle.url(forResource: "ffmpeg", withExtension: nil) else { return nil }
        // deno is optional: if it isn't bundled, the app keeps working (degraded).
        let deno = bundle.url(forResource: "deno", withExtension: nil)
        let nightlyURL = BinaryLocator.nightlyYtdlpURL(appSupportDirectory: appSupportDirectory)
        let nightly = fileExists(nightlyURL) && isExecutable(nightlyURL) ? nightlyURL : nil
        return BundledBinaries(
            ytdlp: bundledYtdlp,
            ffmpegDirectory: ffmpeg.deletingLastPathComponent(),
            deno: deno,
            nightlyYtdlp: nightly
        )
    }
}
