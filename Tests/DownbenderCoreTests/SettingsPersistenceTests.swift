import Testing
import Foundation
@testable import DownbenderCore

@MainActor private func makeModel(defaults: UserDefaults, fallbackDestination: URL = URL(fileURLWithPath: "/tmp/dest")) -> AppModel {
    AppModel(
        binaries: BundledBinaries(
            ytdlp: URL(fileURLWithPath: "/fake/yt-dlp"),
            ffmpegDirectory: URL(fileURLWithPath: "/ff"),
            deno: nil
        ),
        destination: fallbackDestination,
        tmpDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("sp-tmp-\(UUID().uuidString)"),
        appSupportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("sp-\(UUID().uuidString)"),
        cookiesBrowser: nil,
        runner: FakeProcessRunner(),
        defaults: defaults,
        directSessionFactory: { FailingURLProtocol.session() }
    )
}

@MainActor
@Test func maxConcurrentPersistsAcrossModels() {
    let suite = "sp-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = makeModel(defaults: defaults)
    #expect(first.maxConcurrent == 2) // default
    first.maxConcurrent = 4
    #expect(makeModel(defaults: defaults).maxConcurrent == 4)
}

@MainActor
@Test func maxConcurrentOutOfRangeFallsBackToDefault() {
    let suite = "sp-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(9, forKey: AppModel.maxConcurrentKey)
    #expect(makeModel(defaults: defaults).maxConcurrent == 2)
}

@MainActor
@Test func destinationPersistsWhenTheFolderStillExists() throws {
    let suite = "sp-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sp-dest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let first = makeModel(defaults: defaults)
    first.destination = folder
    #expect(makeModel(defaults: defaults).destination.path == folder.path)
}

@MainActor
@Test func deletedDestinationFallsBackToTheParameter() {
    let suite = "sp-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("/tmp/gone-\(UUID().uuidString)", forKey: AppModel.destinationKey)
    let fallback = URL(fileURLWithPath: "/tmp/dest")
    #expect(makeModel(defaults: defaults, fallbackDestination: fallback).destination.path == fallback.path)
}
