import Testing
import Foundation
@testable import DownbenderCore

@MainActor private func makeRoutingModel(runner: ProcessRunning) -> AppModel {
    AppModel(
        binaries: BundledBinaries(ytdlp: URL(fileURLWithPath: "/fake/yt-dlp"),
                                  ffmpegDirectory: URL(fileURLWithPath: "/ff"), deno: nil),
        destination: URL(fileURLWithPath: "/tmp/dest"),
        tmpDirectory: URL(fileURLWithPath: "/tmp/work"),
        appSupportDirectory: URL(fileURLWithPath: "/tmp/support"),
        runner: runner,
        directSessionFactory: { FailingURLProtocol.session() })
}

@MainActor private func waitUntilNotProbing(_ item: DownloadItem) async {
    var waited = 0
    while item.state == .probing, waited < 300 { waited += 1; try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor
@Test func directFileExtensionCreatesDirectCardWithoutProbing() async {
    let runner = FakeProcessRunner(exitCode: 0)
    let model = makeRoutingModel(runner: runner)

    model.addURL("https://example.com/a.zip")

    #expect(model.queue.items.count == 1)
    let item = model.queue.items[0]
    await waitUntilNotProbing(item)
    #expect(item.state == .readyToChoose)
    if case .directFile = item.source {} else { Issue.record("expected .directFile source") }
    #expect(runner.recordedArguments.allArguments.isEmpty) // yt-dlp never invoked
}

@MainActor
@Test func mediaFileExtensionCreatesAmbiguousCardWithoutProbing() {
    let runner = FakeProcessRunner(exitCode: 0)
    let model = makeRoutingModel(runner: runner)
    model.addURL("https://example.com/clip.mp4")
    #expect(model.queue.items.count == 1)
    let item = model.queue.items[0]
    #expect(item.state == .readyToChoose)
    if case .ambiguous = item.source {} else { Issue.record("expected .ambiguous source") }
    #expect(runner.recordedArguments.allArguments.isEmpty)
}

@MainActor
@Test func genericExtractorProbeYieldsAmbiguousCard() async throws {
    let json = #"{"id":"x","title":"Raw","extractor":"generic","formats":[{"format_id":"0","height":720,"vcodec":"avc1","acodec":"mp4a"}]}"#
    let runner = FakeProcessRunner(stdoutLines: [json], exitCode: 0)
    let model = makeRoutingModel(runner: runner)
    model.addURL("https://weird.example.com/thing")
    let item = model.queue.items[0]
    await waitUntilNotProbing(item)
    #expect(item.state == .readyToChoose)
    if case .ambiguous = item.source {} else { Issue.record("expected .ambiguous source, got \(item.source)") }
    #expect(item.probe?.isGeneric == true)
}

@MainActor
@Test func specificExtractorProbeStaysMedia() async throws {
    let json = #"{"id":"x","title":"YT","extractor":"youtube","formats":[{"format_id":"0","height":720,"vcodec":"avc1","acodec":"mp4a"}]}"#
    let runner = FakeProcessRunner(stdoutLines: [json], exitCode: 0)
    let model = makeRoutingModel(runner: runner)
    model.addURL("https://youtu.be/abc123")
    let item = model.queue.items[0]
    await waitUntilNotProbing(item)
    #expect(item.state == .readyToChoose)
    #expect(item.source == .media)
}
