import Testing
import Foundation
@testable import DownbenderCore

/// Builds a minimal fake .app bundle on disk with the given bundle id.
private func makeFakeApp(at url: URL, bundleID: String, marker: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": "9.9.9"]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
    try marker.data(using: .utf8)!.write(to: url.appendingPathComponent("Contents/MacOS/marker"))
}

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("selfupdate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct ForcedReplacementError: Error {}

@Test func installSwapsBundleAfterValidatingIdentityAndSignature() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let installed = root.appendingPathComponent("Installed/Downbender.app")
    let fresh = root.appendingPathComponent("Extracted/Downbender.app")
    try makeFakeApp(at: installed, bundleID: "com.naztirs.downbender", marker: "old")
    try makeFakeApp(at: fresh, bundleID: "com.naztirs.downbender", marker: "new")

    let runner = FakeProcessRunner()
    let updater = AppSelfUpdater(
        runner: runner,
        installURL: installed,
        expectedBundleID: "com.naztirs.downbender",
        appSupportDirectory: root.appendingPathComponent("Support")
    )
    try await updater.install(appAt: fresh)

    let marker = try String(contentsOf: installed.appendingPathComponent("Contents/MacOS/marker"), encoding: .utf8)
    #expect(marker == "new")
    #expect(runner.recordedArguments.arguments == [
        "--verify", "--deep", "--strict", "--verbose=2", fresh.path,
    ])
    // No leftover backup directories next to the installed app.
    let siblings = try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
    #expect(siblings == ["Downbender.app"])
}

@Test func installRejectsForeignBundle() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let installed = root.appendingPathComponent("Installed/Downbender.app")
    let fresh = root.appendingPathComponent("Extracted/Impostor.app")
    try makeFakeApp(at: installed, bundleID: "com.naztirs.downbender", marker: "old")
    try makeFakeApp(at: fresh, bundleID: "com.evil.impostor", marker: "evil")

    let runner = FakeProcessRunner()
    let updater = AppSelfUpdater(
        runner: runner,
        installURL: installed,
        expectedBundleID: "com.naztirs.downbender",
        appSupportDirectory: root.appendingPathComponent("Support")
    )
    await #expect(throws: SelfUpdateError.self) { try await updater.install(appAt: fresh) }

    // The installed copy is untouched.
    let marker = try String(contentsOf: installed.appendingPathComponent("Contents/MacOS/marker"), encoding: .utf8)
    #expect(marker == "old")
    #expect(runner.recordedArguments.allArguments.isEmpty)
}

@Test func installRejectsInvalidSignatureBeforeTouchingCurrentApp() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let installed = root.appendingPathComponent("Installed/Downbender.app")
    let fresh = root.appendingPathComponent("Extracted/Downbender.app")
    try makeFakeApp(at: installed, bundleID: "com.naztirs.downbender", marker: "old")
    try makeFakeApp(at: fresh, bundleID: "com.naztirs.downbender", marker: "tampered")

    let runner = FakeProcessRunner(stderr: "code object is not signed at all", exitCode: 1)
    let updater = AppSelfUpdater(
        runner: runner,
        installURL: installed,
        expectedBundleID: "com.naztirs.downbender",
        appSupportDirectory: root.appendingPathComponent("Support")
    )
    await #expect(throws: SelfUpdateError.invalidCodeSignature("code object is not signed at all")) {
        try await updater.install(appAt: fresh)
    }

    let marker = try String(
        contentsOf: installed.appendingPathComponent("Contents/MacOS/marker"),
        encoding: .utf8
    )
    #expect(marker == "old")
    #expect(FileManager.default.fileExists(atPath: fresh.path))
}

@Test func safeSaveReplacementFailureLeavesInstalledAppAndEngineUntouched() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let installed = root.appendingPathComponent("Installed/Downbender.app")
    let fresh = root.appendingPathComponent("Extracted/Downbender.app")
    let support = root.appendingPathComponent("Support")
    let engine = support.appendingPathComponent("yt-dlp_macos")
    try makeFakeApp(at: installed, bundleID: "com.naztirs.downbender", marker: "old")
    try makeFakeApp(at: fresh, bundleID: "com.naztirs.downbender", marker: "new")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try Data("current engine".utf8).write(to: engine)

    let updater = AppSelfUpdater(
        runner: FakeProcessRunner(),
        installURL: installed,
        expectedBundleID: "com.naztirs.downbender",
        appSupportDirectory: support,
        replaceInstalledApp: { _, _ in throw ForcedReplacementError() }
    )
    await #expect(throws: ForcedReplacementError.self) {
        try await updater.install(appAt: fresh)
    }

    let installedMarker = try String(
        contentsOf: installed.appendingPathComponent("Contents/MacOS/marker"),
        encoding: .utf8
    )
    let freshMarker = try String(
        contentsOf: fresh.appendingPathComponent("Contents/MacOS/marker"),
        encoding: .utf8
    )
    #expect(installedMarker == "old")
    #expect(freshMarker == "new")
    #expect(FileManager.default.fileExists(atPath: engine.path))
    let installedSiblings = try FileManager.default.contentsOfDirectory(
        atPath: installed.deletingLastPathComponent().path
    )
    #expect(installedSiblings == ["Downbender.app"])
    let cleanupMarker = AppSelfUpdater.deferredCleanupMarkerURL(appSupportDirectory: support)
    #expect(!FileManager.default.fileExists(atPath: cleanupMarker.path))
}

@Test func installDefersStaleEngineOverrideCleanupAndPreservesNightly() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let installed = root.appendingPathComponent("Installed/Downbender.app")
    let fresh = root.appendingPathComponent("Extracted/Downbender.app")
    let support = root.appendingPathComponent("Support")
    try makeFakeApp(at: installed, bundleID: "com.naztirs.downbender", marker: "old")
    try makeFakeApp(at: fresh, bundleID: "com.naztirs.downbender", marker: "new")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let engine = support.appendingPathComponent("yt-dlp_macos")
    let nightly = support.appendingPathComponent("yt-dlp-nightly_macos")
    try Data("stale".utf8).write(to: engine)
    try Data("nightly".utf8).write(to: nightly)

    let updater = AppSelfUpdater(
        runner: FakeProcessRunner(),
        installURL: installed,
        expectedBundleID: "com.naztirs.downbender",
        appSupportDirectory: support
    )
    try await updater.install(appAt: fresh)

    let cleanupMarker = AppSelfUpdater.deferredCleanupMarkerURL(appSupportDirectory: support)
    // The old process may still launch yt-dlp before restart, so neither it nor the marker
    // may disappear during the swap.
    #expect(FileManager.default.fileExists(atPath: engine.path))
    #expect(FileManager.default.fileExists(atPath: nightly.path))
    #expect(FileManager.default.fileExists(atPath: cleanupMarker.path))

    try AppSelfUpdater.finishDeferredCleanup(appSupportDirectory: support)

    // The new app performs this before BinaryLocator, so its bundled engine is selected.
    #expect(!FileManager.default.fileExists(atPath: engine.path))
    #expect(FileManager.default.fileExists(atPath: nightly.path))
    #expect(try Data(contentsOf: nightly) == Data("nightly".utf8))
    #expect(!FileManager.default.fileExists(atPath: cleanupMarker.path))
}

@Test func deferredCleanupWithoutMarkerPreservesEngineOverride() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("Support")
    let engine = support.appendingPathComponent("yt-dlp_macos")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: engine)

    try AppSelfUpdater.finishDeferredCleanup(appSupportDirectory: support)

    #expect(FileManager.default.fileExists(atPath: engine.path))
}

@Test func deferredCleanupIgnoresUnrecognizedMarker() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("Support")
    let engine = support.appendingPathComponent("yt-dlp_macos")
    let marker = AppSelfUpdater.deferredCleanupMarkerURL(appSupportDirectory: support)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try Data("not-created-by-downbender".utf8).write(to: marker)
    try Data("keep".utf8).write(to: engine)

    try AppSelfUpdater.finishDeferredCleanup(appSupportDirectory: support)

    #expect(FileManager.default.fileExists(atPath: engine.path))
    #expect(FileManager.default.fileExists(atPath: marker.path))
}

@Test func extractBuildsDittoInvocation() async {
    let runner = FakeProcessRunner()   // exit 0 but extracts nothing
    let root = try! tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let zip = root.appendingPathComponent("Downbender.zip")
    try! Data().write(to: zip)

    let updater = AppSelfUpdater(
        runner: runner,
        installURL: root.appendingPathComponent("X.app"),
        expectedBundleID: "com.naztirs.downbender",
        appSupportDirectory: root
    )
    await #expect(throws: SelfUpdateError.appNotFoundInArchive) {
        _ = try await updater.extract(zip: zip)
    }
    let args = runner.recordedArguments.arguments
    #expect(args.count == 4)
    #expect(args[0] == "-x")
    #expect(args[1] == "-k")
    #expect(args[2] == zip.path)
}

@Test func extractFindsAppInsideRealZip() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Downbender.app")
    try makeFakeApp(at: app, bundleID: "com.naztirs.downbender", marker: "zipped")
    let zip = root.appendingPathComponent("Downbender.zip")
    let dittoProcess = Process()
    dittoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    dittoProcess.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
    try dittoProcess.run()
    dittoProcess.waitUntilExit()

    let updater = AppSelfUpdater(
        runner: ProcessRunner(),
        installURL: root.appendingPathComponent("X.app"),
        expectedBundleID: "com.naztirs.downbender",
        appSupportDirectory: root
    )
    let extracted = try await updater.extract(zip: zip)
    #expect(extracted.lastPathComponent == "Downbender.app")
    let marker = try String(contentsOf: extracted.appendingPathComponent("Contents/MacOS/marker"), encoding: .utf8)
    #expect(marker == "zipped")
}
