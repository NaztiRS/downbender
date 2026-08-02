import Foundation

public enum SelfUpdateError: Error, Equatable, LocalizedError {
    case badStatus(Int)
    case extractionFailed(String)
    case appNotFoundInArchive
    case bundleMismatch(expected: String, found: String?)
    case invalidCodeSignature(String)

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
        case .invalidCodeSignature(let details):
            let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "The downloaded app has an invalid code signature."
                : "The downloaded app has an invalid code signature: \(trimmed)"
        }
    }
}

/// Downloads the released app zip and swaps it into place. The swap works while the app
/// is running (open inodes stay alive), and self-downloaded files carry no quarantine
/// flag, so the relaunch does not re-trigger Gatekeeper.
public struct AppSelfUpdater: Sendable {
    public static let appZipURL = URL(string: "https://github.com/NaztiRS/downbender/releases/latest/download/Downbender.zip")!
    static let deferredCleanupMarkerFilename = ".app-update-engine-cleanup"
    private static let deferredCleanupMarkerContents = Data("remove-yt-dlp-override-v1\n".utf8)

    let runner: ProcessRunning
    let installURL: URL
    let expectedBundleID: String
    let appSupportDirectory: URL
    private let replaceInstalledApp: @Sendable (URL, URL) throws -> Void

    public init(runner: ProcessRunning, installURL: URL, expectedBundleID: String, appSupportDirectory: URL) {
        self.init(
            runner: runner,
            installURL: installURL,
            expectedBundleID: expectedBundleID,
            appSupportDirectory: appSupportDirectory,
            replaceInstalledApp: Self.replaceSafely
        )
    }

    init(
        runner: ProcessRunning,
        installURL: URL,
        expectedBundleID: String,
        appSupportDirectory: URL,
        replaceInstalledApp: @escaping @Sendable (URL, URL) throws -> Void
    ) {
        self.runner = runner
        self.installURL = installURL
        self.expectedBundleID = expectedBundleID
        self.appSupportDirectory = appSupportDirectory
        self.replaceInstalledApp = replaceInstalledApp
    }

    /// Full pipeline: download → extract → validate → swap → deferred engine cleanup marker.
    public func update(
        session: URLSession = .shared,
        from url: URL = appZipURL,
        onProgress: @escaping @Sendable (Double?) -> Void = { _ in }
    ) async throws {
        onProgress(0)
        let zip = try await download(session: session, from: url) { fraction in
            onProgress(Self.overallProgress(forDownloadFraction: fraction))
        }
        defer { try? FileManager.default.removeItem(at: zip) }
        onProgress(0.92)
        let extracted = try await extract(zip: zip)
        defer { try? FileManager.default.removeItem(at: extracted.deletingLastPathComponent()) }
        onProgress(0.97)
        try await install(appAt: extracted)
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
        let delegate = DownloadProgressDelegate(
            onProgress: onProgress,
            expectedBytes: expected,
            temporaryFileExtension: "zip"
        )
        let (tmp, response) = try await delegate.download(session: session, from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw SelfUpdateError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return tmp
    }

    /// A HEAD to learn the asset size up front, so the bar can show a real percentage even when
    /// the download itself arrives without a total. Best-effort: nil on any failure or unknown size.
    static func headContentLength(url: URL, session: URLSession) async throws -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode)
        else { return nil }
        let length = http.expectedContentLength
        return length > 0 ? length : nil
    }

    /// ditto (not unzip) preserves bundle structure, permissions and the ad-hoc signature.
    func extract(zip: URL) async throws -> URL {
        let dest = zip.deletingPathExtension().appendingPathExtension("extracted")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var shouldRemovePartialExtraction = true
        defer {
            if shouldRemovePartialExtraction {
                try? FileManager.default.removeItem(at: dest)
            }
        }
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
        shouldRemovePartialExtraction = false
        return app
    }

    /// Validates and swaps the new bundle with Foundation's safe-save operation. The running
    /// process may still need its Application Support engine, so cleanup is deferred until the
    /// next launch rather than deleting that executable out from under the old process.
    public func install(appAt newApp: URL) async throws {
        let plist = newApp.appendingPathComponent("Contents/Info.plist")
        let found = (NSDictionary(contentsOf: plist)?["CFBundleIdentifier"]) as? String
        guard found == expectedBundleID else {
            throw SelfUpdateError.bundleMismatch(expected: expectedBundleID, found: found)
        }

        let signature = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", "--verbose=2", newApp.path],
            onStdoutLine: { _ in }
        )
        guard signature.exitCode == 0 else {
            throw SelfUpdateError.invalidCodeSignature(signature.stderr)
        }

        // A single safe-save replacement removes the crash window created by moving the
        // installed app away first. If replacement fails, the original remains at installURL.
        try replaceInstalledApp(installURL, newApp)
        // The swap is already committed. A marker write failure must not report the irreversible
        // install as failed; in that rare case the existing engine override is simply preserved.
        try? markDeferredCleanup()
    }

    /// Completes cleanup requested by a successful app swap. Call this once during the next
    /// launch, before `BundledBinaries.locate`, so the updated bundle's engine wins. Removing the
    /// marker last makes an interrupted cleanup retryable on a later launch.
    public static func finishDeferredCleanup(
        appSupportDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let marker = deferredCleanupMarkerURL(appSupportDirectory: appSupportDirectory)
        guard fileManager.fileExists(atPath: marker.path) else { return }
        guard try Data(contentsOf: marker) == deferredCleanupMarkerContents else { return }

        let engineOverride = appSupportDirectory.appendingPathComponent("yt-dlp_macos")
        if fileManager.fileExists(atPath: engineOverride.path) {
            try fileManager.removeItem(at: engineOverride)
        }
        try fileManager.removeItem(at: marker)
    }

    static func deferredCleanupMarkerURL(appSupportDirectory: URL) -> URL {
        appSupportDirectory.appendingPathComponent(deferredCleanupMarkerFilename)
    }

    private func markDeferredCleanup(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        try Self.deferredCleanupMarkerContents.write(
            to: Self.deferredCleanupMarkerURL(appSupportDirectory: appSupportDirectory),
            options: .atomic
        )
    }

    private static func replaceSafely(installed: URL, replacement: URL) throws {
        _ = try FileManager.default.replaceItemAt(
            installed,
            withItemAt: replacement,
            backupItemName: nil,
            options: .usingNewMetadataOnly
        )
    }
}
