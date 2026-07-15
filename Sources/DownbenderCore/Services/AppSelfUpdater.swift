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
        let zip = try await download(session: session, from: url, onProgress: onProgress)
        let extracted = try await extract(zip: zip)
        try install(appAt: extracted)
    }

    func download(session: URLSession, from url: URL, onProgress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        let delegate = DownloadProgressDelegate(onProgress: onProgress)
        let (tmp, response) = try await session.download(from: url, delegate: delegate)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SelfUpdateError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        // URLSession deletes the temp file when this call returns; move it somewhere stable (.zip for ditto).
        let stable = FileManager.default.temporaryDirectory.appendingPathComponent("Downbender-update-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: tmp, to: stable)
        return stable
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
