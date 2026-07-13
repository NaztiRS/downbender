import Testing
import Foundation
@testable import DownbenderCore

@Test func probeServiceParsesYtdlpJSON() async throws {
    let url = Bundle.module.url(forResource: "probe", withExtension: "json", subdirectory: "Fixtures")!
    let json = try String(contentsOf: url, encoding: .utf8)
    let runner = FakeProcessRunner(stdoutLines: [json], exitCode: 0)
    let service = ProbeService(runner: runner, ytdlpURL: URL(fileURLWithPath: "/fake/yt-dlp"))

    guard case .video(let result) = try await service.probe(url: "https://youtu.be/abc123") else {
        Issue.record("expected .video")
        return
    }
    #expect(result.title == "Test video")
    #expect(result.availableFormats.first == .video(height: 1080))

    // Playlists must resolve in ONE fast call: flat probing is non-negotiable.
    #expect(runner.recordedArguments.arguments.contains("--flat-playlist"))
}

@Test func probeServiceDetectsPlaylists() async throws {
    let url = Bundle.module.url(forResource: "playlist", withExtension: "json", subdirectory: "Fixtures")!
    let json = try String(contentsOf: url, encoding: .utf8)
    let runner = FakeProcessRunner(stdoutLines: [json], exitCode: 0)
    let service = ProbeService(runner: runner, ytdlpURL: URL(fileURLWithPath: "/fake/yt-dlp"))

    guard case .playlist(let playlist) = try await service.probe(url: "https://www.youtube.com/playlist?list=PLtest123") else {
        Issue.record("expected .playlist")
        return
    }
    #expect(playlist.title == "Test playlist")
    #expect(playlist.entries.count == 3)
}

@Test func probeServiceDropsNoPlaylistWhenExpandingPlaylists() async throws {
    let url = Bundle.module.url(forResource: "playlist", withExtension: "json", subdirectory: "Fixtures")!
    let json = try String(contentsOf: url, encoding: .utf8)
    let runner = FakeProcessRunner(stdoutLines: [json], exitCode: 0)
    let service = ProbeService(runner: runner, ytdlpURL: URL(fileURLWithPath: "/fake/yt-dlp"))

    _ = try await service.probe(url: "https://www.youtube.com/watch?v=a&list=RDx", expandPlaylist: true)

    // Without dropping --no-playlist, a watch?v=X&list=Y URL would resolve to the single video.
    let recorded = runner.recordedArguments.arguments
    #expect(!recorded.contains("--no-playlist"))
    #expect(recorded.contains("--flat-playlist"))
}

@Test func probeServiceThrowsOnNonZeroExit() async {
    let runner = FakeProcessRunner(stderr: "ERROR: nope", exitCode: 1)
    let service = ProbeService(runner: runner, ytdlpURL: URL(fileURLWithPath: "/fake/yt-dlp"))
    await #expect(throws: ProbeError.self) {
        _ = try await service.probe(url: "https://youtu.be/abc123")
    }
}

@Test func probeServicePassesDenoRuntimeAndCookiesFlags() async throws {
    let url = Bundle.module.url(forResource: "probe", withExtension: "json", subdirectory: "Fixtures")!
    let json = try String(contentsOf: url, encoding: .utf8)
    let runner = FakeProcessRunner(stdoutLines: [json], exitCode: 0)
    let service = ProbeService(
        runner: runner,
        ytdlpURL: URL(fileURLWithPath: "/fake/yt-dlp"),
        denoURL: URL(fileURLWithPath: "/app/deno")
    )

    _ = try await service.probe(url: "https://youtu.be/abc123", cookiesBrowser: "chrome")

    let recorded = runner.recordedArguments.arguments
    guard let runtimeIndex = recorded.firstIndex(of: "--js-runtimes") else {
        Issue.record("missing --js-runtimes")
        return
    }
    #expect(recorded[runtimeIndex + 1] == "deno:/app/deno")

    guard let cookiesIndex = recorded.firstIndex(of: "--cookies-from-browser") else {
        Issue.record("missing --cookies-from-browser")
        return
    }
    #expect(recorded[cookiesIndex + 1] == "chrome")
}
