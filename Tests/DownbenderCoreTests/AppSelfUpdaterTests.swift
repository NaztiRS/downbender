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

@Test func installSwapsBundleValidatingIdentifier() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let installed = root.appendingPathComponent("Installed/Downbender.app")
    let fresh = root.appendingPathComponent("Extracted/Downbender.app")
    try makeFakeApp(at: installed, bundleID: "com.naztirs.downbender", marker: "old")
    try makeFakeApp(at: fresh, bundleID: "com.naztirs.downbender", marker: "new")

    let updater = AppSelfUpdater(
        runner: FakeProcessRunner(),
        installURL: installed,
        expectedBundleID: "com.naztirs.downbender",
        appSupportDirectory: root.appendingPathComponent("Support")
    )
    try updater.install(appAt: fresh)

    let marker = try String(contentsOf: installed.appendingPathComponent("Contents/MacOS/marker"), encoding: .utf8)
    #expect(marker == "new")
    // No leftover backup directories next to the installed app.
    let siblings = try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
    #expect(siblings == ["Downbender.app"])
}

@Test func installRejectsForeignBundle() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let installed = root.appendingPathComponent("Installed/Downbender.app")
    let fresh = root.appendingPathComponent("Extracted/Impostor.app")
    try makeFakeApp(at: installed, bundleID: "com.naztirs.downbender", marker: "old")
    try makeFakeApp(at: fresh, bundleID: "com.evil.impostor", marker: "evil")

    let updater = AppSelfUpdater(
        runner: FakeProcessRunner(),
        installURL: installed,
        expectedBundleID: "com.naztirs.downbender",
        appSupportDirectory: root.appendingPathComponent("Support")
    )
    #expect(throws: SelfUpdateError.self) { try updater.install(appAt: fresh) }

    // The installed copy is untouched.
    let marker = try String(contentsOf: installed.appendingPathComponent("Contents/MacOS/marker"), encoding: .utf8)
    #expect(marker == "old")
}

@Test func installRemovesStaleEngineOverride() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let installed = root.appendingPathComponent("Installed/Downbender.app")
    let fresh = root.appendingPathComponent("Extracted/Downbender.app")
    let support = root.appendingPathComponent("Support")
    try makeFakeApp(at: installed, bundleID: "com.naztirs.downbender", marker: "old")
    try makeFakeApp(at: fresh, bundleID: "com.naztirs.downbender", marker: "new")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let engine = support.appendingPathComponent("yt-dlp_macos")
    try "stale".data(using: .utf8)!.write(to: engine)

    let updater = AppSelfUpdater(
        runner: FakeProcessRunner(),
        installURL: installed,
        expectedBundleID: "com.naztirs.downbender",
        appSupportDirectory: support
    )
    try updater.install(appAt: fresh)

    // The new app ships a fresh engine; the Application Support override must not shadow it (BinaryLocator prefers it).
    #expect(!FileManager.default.fileExists(atPath: engine.path))
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
