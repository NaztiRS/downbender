import Testing
import Foundation
@testable import DownbenderCore

@Test func updaterParsesTagNameFromReleaseJSON() throws {
    let json = #"{"tag_name":"2025.06.30","name":"yt-dlp 2025.06.30","assets":[]}"#
    let tag = try UpdaterService.parseTagName(Data(json.utf8))
    #expect(tag == "2025.06.30")
}

@Test func updaterParsesTagNameTrimmingWhitespace() throws {
    let json = #"{"tag_name":"  2025.01.02  "}"#
    let tag = try UpdaterService.parseTagName(Data(json.utf8))
    #expect(tag == "2025.01.02")
}

@Test func updaterThrowsOnMalformedReleaseJSON() {
    #expect(throws: UpdaterError.self) {
        _ = try UpdaterService.parseTagName(Data("not json".utf8))
    }
}

@Test func updaterThrowsOnEmptyTagName() {
    #expect(throws: UpdaterError.self) {
        _ = try UpdaterService.parseTagName(Data(#"{"tag_name":""}"#.utf8))
    }
}

@Test func updaterIsUpToDateComparesTrimmedVersions() {
    #expect(UpdaterService.isUpToDate(installed: "2025.06.30", latest: "2025.06.30"))
    #expect(UpdaterService.isUpToDate(installed: " 2025.06.30 ", latest: "2025.06.30"))
    #expect(!UpdaterService.isUpToDate(installed: "2025.05.01", latest: "2025.06.30"))
}

@Test func updaterReadsInstalledVersionFromYtdlp() async throws {
    let runner = FakeProcessRunner(stdoutLines: ["2025.06.30"], exitCode: 0)
    let service = UpdaterService(appSupportDirectory: URL(fileURLWithPath: "/tmp/downbender"))
    let version = try await service.installedVersion(runner: runner, ytdlpURL: URL(fileURLWithPath: "/fake/yt-dlp"))
    #expect(version == "2025.06.30")
    #expect(runner.recordedArguments.arguments == ["--version"])
}

@Test func updaterThrowsWhenYtdlpVersionFails() async {
    let runner = FakeProcessRunner(stderr: "boom", exitCode: 1)
    let service = UpdaterService(appSupportDirectory: URL(fileURLWithPath: "/tmp/downbender"))
    await #expect(throws: UpdaterError.self) {
        _ = try await service.installedVersion(runner: runner, ytdlpURL: URL(fileURLWithPath: "/fake/yt-dlp"))
    }
}

@Test func updaterThrowsWhenVersionOutputEmpty() async {
    let runner = FakeProcessRunner(stdoutLines: ["   "], exitCode: 0)
    let service = UpdaterService(appSupportDirectory: URL(fileURLWithPath: "/tmp/downbender"))
    await #expect(throws: UpdaterError.self) {
        _ = try await service.installedVersion(runner: runner, ytdlpURL: URL(fileURLWithPath: "/fake/yt-dlp"))
    }
}
