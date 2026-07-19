import Foundation

public enum SelfUpdateError: Error, Equatable, LocalizedError {
    case badStatus(Int)
    case extractionFailed(String)
    case appNotFoundInArchive
    case bundleMismatch(expected: String, found: String?)

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code):
            return "GitHub returned HTTP \(code)."
        case .extractionFailed(let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Couldn't extract the update." : trimmed
        case .appNotFoundInArchive:
            return "The downloaded update doesn't contain the app."
        case .bundleMismatch(let expected, let found):
            return "The downloaded app is \(found ?? "unidentified"), expected \(expected)."
        }
    }
}

/// Downloads the released app zip and swaps it into place. The swap works while the app
/// is running (open inodes stay alive), and self-downloaded files carry no quarantine
/// flag, so the relaunch does not re-trigger Gatekeeper.
public struct AppSelfUpdater: Sendable {
    public static let appZipURL = URL(string: "https://github.com/NaztiRS/downbender/releases/latest/download/Downbender.zip")!

    let runner: ProcessRunning
    let installURL: URL
    let expectedBundleID: String
    let appSupportDirectory: URL

    public init(runner: ProcessRunning, installURL: URL, expectedBundleID: String, appSupportDirectory: URL) {
        self.runner = runner
        self.installURL = installURL
        self.expectedBundleID = expectedBundleID
        self.appSupportDirectory = appSupportDirectory
    }

    /// Full pipeline: download → extract → validate → swap → engine cleanup.
    public func update(
        session: URLSession = .shared,
        from url: URL = appZipURL,
        onProgress: @escaping @Sendable (Double?) -> Void = { _ in }
    ) async throws {
        onProgress(0)
        let zip = try await download(session: session, from: url) { fraction in
            onProgress(Self.overallProgress(forDownloadFraction: fraction))
        }
        onProgress(0.92)
        let extracted = try await extract(zip: zip)
        onProgress(0.97)
        try install(appAt: extracted)
        onProgress(1)
    }

    /// The network transfer owns most of the bar; the remaining space makes extraction and
    /// installation visible instead of letting the UI jump directly from download to completion.
    static func overallProgress(forDownloadFraction fraction: Double?) -> Double? {
        guard let fraction else { return nil }
        return min(max(fraction, 0), 1) * 0.9
    }

    func download(session: URLSession, from url: URL, onProgress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        // The GET can arrive without a total (chunked behind GitHub's CDN redirect), leaving the bar
        // indeterminate. A HEAD reliably returns the size, so progress can show a real percentage.
        let expected = try? await Self.headContentLength(url: url, session: session)
        let delegate = DownloadProgressDelegate(onProgress: onProgress, expectedBytes: expected)
        let (tmp, response) = try await session.download(from: url, delegate: delegate)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SelfUpdateError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        // URLSession deletes the temp file when this call returns; move it somewhere stable (.zip for ditto).
        let stable = FileManager.default.temporaryDirectory.appendingPathComponent("Downbender-update-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: tmp, to: stable)
        return stable
    }

    /// A HEAD to learn the asset size up front, so the bar can show a real percentage even when
    /// the download itself arrives without a total. Best-effort: nil on any failure or unknown size.
    static func headContentLength(url: URL, session: URLSession) async throws -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        let length = (response as? HTTPURLResponse)?.expectedContentLength ?? -1
        return length > 0 ? length : nil
    }

    /// ditto (not unzip) preserves bundle structure, permissions and the ad-hoc signature.
    func extract(zip: URL) async throws -> URL {
        let dest = zip.deletingPathExtension().appendingPathExtension("extracted")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", zip.path, dest.path],
            onStdoutLine: { _ in }
        )
        guard result.exitCode == 0 else { throw SelfUpdateError.extractionFailed(result.stderr) }
        let contents = try FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw SelfUpdateError.appNotFoundInArchive
        }
        return app
    }

    /// Swaps the new bundle into place with rollback on failure, then drops the Application
    /// Support engine copy: a stale override would shadow the fresh bundled engine (BinaryLocator prefers it).
    public func install(appAt newApp: URL) throws {
        let plist = newApp.appendingPathComponent("Contents/Info.plist")
        let found = (NSDictionary(contentsOf: plist)?["CFBundleIdentifier"]) as? String
        guard found == expectedBundleID else {
            throw SelfUpdateError.bundleMismatch(expected: expectedBundleID, found: found)
        }

        let fm = FileManager.default
        // Same-directory hidden backup guarantees a same-volume rename.
        let backup = installURL.deletingLastPathComponent()
            .appendingPathComponent(".\(installURL.lastPathComponent).old-\(UUID().uuidString)")
        try fm.moveItem(at: installURL, to: backup)
        do {
            try fm.moveItem(at: newApp, to: installURL)
        } catch {
            try? fm.moveItem(at: backup, to: installURL)
            throw error
        }
        try? fm.removeItem(at: backup)
        try? fm.removeItem(at: appSupportDirectory.appendingPathComponent("yt-dlp_macos"))
    }
}
