import Testing
import Foundation
@testable import DownbenderCore

// The HEAD fallback (probe failed → maybe a file) lives in the serialized suite: it drives the
// process-global mock handler to return a specific content-type.
extension DirectDownloadTests {
    @MainActor
    private func makeFallbackModel(runner: ProcessRunning) -> AppModel {
        AppModel(
            binaries: BundledBinaries(ytdlp: URL(fileURLWithPath: "/fake/yt-dlp"),
                                      ffmpegDirectory: URL(fileURLWithPath: "/ff"), deno: nil),
            destination: URL(fileURLWithPath: "/tmp/dest"),
            tmpDirectory: URL(fileURLWithPath: "/tmp/work"),
            appSupportDirectory: URL(fileURLWithPath: "/tmp/support"),
            runner: runner,
            directSessionFactory: { MockURLProtocol.session() })
    }

    @MainActor
    private func waitNotProbing(_ item: DownloadItem) async {
        var waited = 0
        while item.state == .probing, waited < 300 { waited += 1; try? await Task.sleep(for: .milliseconds(5)) }
    }

    @MainActor
    @Test func probeFailureWithHTMLStaysProbeFailed() async {
        MockURLProtocol.respond(status: 200, data: Data(), headers: ["Content-Type": "text/html; charset=utf-8"])
        let model = makeFallbackModel(runner: FakeProcessRunner(stderr: "ERROR: nope", exitCode: 1))
        model.addURL("https://weird.example.com/thing")
        let item = model.queue.items[0]
        await waitNotProbing(item)
        guard case .probeFailed(let message) = item.state else { Issue.record("expected .probeFailed, got \(item.state)"); return }
        // A web page must produce a clear message, not yt-dlp's raw "Unsupported URL" error.
        #expect(message.contains("web page"))
    }

    @MainActor
    @Test func probeFailureWithFileContentTypeBecomesDirectFile() async {
        MockURLProtocol.respond(status: 200, data: Data(), headers: ["Content-Type": "application/zip"])
        let model = makeFallbackModel(runner: FakeProcessRunner(stderr: "ERROR: nope", exitCode: 1))
        model.addURL("https://weird.example.com/thing")
        let item = model.queue.items[0]
        await waitNotProbing(item)
        #expect(item.state == .readyToChoose)
        if case .directFile = item.source {} else { Issue.record("expected .directFile, got \(item.source)") }
    }
}
