import Testing
import Foundation
@testable import DownbenderCore

private func makeTestBundle() throws -> (root: URL, bundle: Bundle, stable: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("binary-locator-\(UUID().uuidString)")
    let bundleURL = root.appendingPathComponent("Test.bundle")
    let resources = bundleURL.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

    let plist: [String: Any] = [
        "CFBundleIdentifier": "com.downbender.tests.\(UUID().uuidString)",
        "CFBundleName": "BinaryLocatorTests",
        "CFBundlePackageType": "BNDL",
        "CFBundleVersion": "1",
    ]
    let plistData = try PropertyListSerialization.data(
        fromPropertyList: plist,
        format: .xml,
        options: 0
    )
    try plistData.write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
    let stable = resources.appendingPathComponent("yt-dlp_macos")
    try Data("stable".utf8).write(to: stable)
    try Data("ffmpeg".utf8).write(to: resources.appendingPathComponent("ffmpeg"))
    return (root, try #require(Bundle(url: bundleURL)), stable)
}

/// Builds a bundle whose yt-dlp ships as an extracted directory (`yt-dlp/yt-dlp` plus its
/// `_internal` tree) instead of the single self-extracting file.
private func makeDirectoryLayoutBundle() throws -> (root: URL, bundle: Bundle, executable: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("binary-locator-dir-\(UUID().uuidString)")
    let bundleURL = root.appendingPathComponent("Test.bundle")
    let resources = bundleURL.appendingPathComponent("Contents/Resources")
    let engine = resources.appendingPathComponent("yt-dlp")
    try FileManager.default.createDirectory(
        at: engine.appendingPathComponent("_internal"),
        withIntermediateDirectories: true
    )

    let plist: [String: Any] = [
        "CFBundleIdentifier": "com.downbender.tests.\(UUID().uuidString)",
        "CFBundleName": "BinaryLocatorTests",
        "CFBundlePackageType": "BNDL",
        "CFBundleVersion": "1",
    ]
    let plistData = try PropertyListSerialization.data(
        fromPropertyList: plist,
        format: .xml,
        options: 0
    )
    try plistData.write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
    let executable = engine.appendingPathComponent("yt-dlp")
    try Data("stable".utf8).write(to: executable)
    try Data("python".utf8).write(to: engine.appendingPathComponent("_internal/libpython.dylib"))
    try Data("ffmpeg".utf8).write(to: resources.appendingPathComponent("ffmpeg"))
    return (root, try #require(Bundle(url: bundleURL)), executable)
}

@Test func locateFindsYtdlpShippedAsADirectory() throws {
    let fixture = try makeDirectoryLayoutBundle()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let binaries = BundledBinaries.locate(
        bundle: fixture.bundle,
        appSupportDirectory: fixture.root.appendingPathComponent("support")
    )

    #expect(binaries?.ytdlp.standardizedFileURL == fixture.executable.standardizedFileURL)
}

@Test func legacyStableOverrideNeverWinsOverBundledYtdlp() {
    let legacyOverride = URL(fileURLWithPath: "/support/yt-dlp_macos")
    let bundled = URL(fileURLWithPath: "/app/yt-dlp_macos")
    let resolved = BinaryLocator.resolveYtdlp(
        updated: legacyOverride,
        bundled: bundled,
        fileExists: { $0 == legacyOverride }
    )

    #expect(resolved == bundled)
}

@Test func stableSelectionAlwaysUsesBundledYtdlp() {
    let stable = URL(fileURLWithPath: "/app/yt-dlp_macos")
    let nightly = URL(fileURLWithPath: "/support/yt-dlp-nightly_macos")
    let resolved = BinaryLocator.resolveYtdlp(
        channel: .stable,
        stable: stable,
        nightly: nightly,
        fileExists: { _ in true },
        isExecutable: { _ in true }
    )

    #expect(resolved == YtdlpEngineDescriptor(channel: .stable, executableURL: stable))
}

@Test func nightlySelectionUsesExecutableInstalledNightly() {
    let stable = URL(fileURLWithPath: "/app/yt-dlp_macos")
    let nightly = URL(fileURLWithPath: "/support/yt-dlp-nightly_macos")
    let binaries = BundledBinaries(
        ytdlp: stable,
        ffmpegDirectory: URL(fileURLWithPath: "/app"),
        deno: nil,
        nightlyYtdlp: nightly
    )
    let resolved = binaries.resolveYtdlp(
        channel: .nightly,
        fileExists: { $0 == nightly },
        isExecutable: { $0 == nightly }
    )

    #expect(binaries.ytdlp == stable)
    #expect(resolved == YtdlpEngineDescriptor(channel: .nightly, executableURL: nightly))
}

@Test(arguments: [false, true])
func unusableNightlyFallsBackToStable(nightlyExists: Bool) {
    let stable = URL(fileURLWithPath: "/app/yt-dlp_macos")
    let nightly = URL(fileURLWithPath: "/support/yt-dlp-nightly_macos")
    let resolved = BinaryLocator.resolveYtdlp(
        channel: .nightly,
        stable: stable,
        nightly: nightly,
        fileExists: { _ in nightlyExists },
        isExecutable: { _ in false }
    )

    #expect(resolved == YtdlpEngineDescriptor(channel: .stable, executableURL: stable))
}

@Test func missingNightlyDescriptorFallsBackToStable() {
    let stable = URL(fileURLWithPath: "/app/yt-dlp_macos")
    let binaries = BundledBinaries(
        ytdlp: stable,
        ffmpegDirectory: URL(fileURLWithPath: "/app"),
        deno: nil
    )
    let resolved = binaries.resolveYtdlp(
        channel: .nightly,
        fileExists: { _ in true },
        isExecutable: { _ in true }
    )

    #expect(resolved == YtdlpEngineDescriptor(channel: .stable, executableURL: stable))
}

@Test func nightlyUsesItsOwnFixedApplicationSupportPath() {
    let support = URL(fileURLWithPath: "/support")

    #expect(BinaryLocator.nightlyYtdlpURL(appSupportDirectory: support) ==
        support.appendingPathComponent("yt-dlp-nightly_macos"))
}

@Test(arguments: [false, true])
func locateExposesOnlyAnExecutableNightly(isExecutable: Bool) throws {
    let fixture = try makeTestBundle()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let support = fixture.root.appendingPathComponent("Support")
    let nightly = support.appendingPathComponent("yt-dlp-nightly_macos")

    let binaries = try #require(BundledBinaries.locate(
        bundle: fixture.bundle,
        appSupportDirectory: support,
        fileExists: { $0 == nightly },
        isExecutable: { $0 == nightly && isExecutable }
    ))

    #expect(binaries.ytdlp == fixture.stable)
    #expect(binaries.nightlyYtdlp == (isExecutable ? nightly : nil))
}
