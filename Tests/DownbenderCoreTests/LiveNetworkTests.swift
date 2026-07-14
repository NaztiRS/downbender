import Testing
import Foundation
@testable import DownbenderCore

// Integration tests that hit the real network. Opt-in only (they need internet and are slow),
// so they don't run in CI: enable with `DOWNBENDER_LIVE_NET=1 scripts/test.sh --filter Live`.
private let liveNet = ProcessInfo.processInfo.environment["DOWNBENDER_LIVE_NET"] != nil
private let pdfURL = "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf"

@Test(.enabled(if: liveNet)) func liveClassifyPdfIsDirect() {
    #expect(DetectionService.classify(pdfURL) == .directFile)
}

@Test(.enabled(if: liveNet)) func liveHeadInfoReadsRealPdf() async throws {
    let info = try await DirectDownloadService().headInfo(url: pdfURL)
    #expect(info.sizeBytes == 13264)
    #expect(info.contentType?.contains("application/pdf") == true)
    #expect(info.suggestedName == "dummy.pdf")
}

@Test(.enabled(if: liveNet)) func liveDownloadRealPdf() async throws {
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("livetmp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: tmp) }
    let delivered = try await DirectDownloadService().download(
        url: pdfURL, destination: dest, tmpDirectory: tmp, onProgress: { _ in })
    #expect(delivered.lastPathComponent == "dummy.pdf")
    let data = try Data(contentsOf: delivered)
    #expect(data.count == 13264)
    #expect(data.prefix(4) == Data("%PDF".utf8))
    #expect(DirectDownloadService.isQuarantined(delivered))
}

@MainActor
@Test(.enabled(if: liveNet)) func liveAppModelDirectPdfFlow() async throws {
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("liveapp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dest) }
    let model = AppModel(
        binaries: BundledBinaries(ytdlp: URL(fileURLWithPath: "/fake"), ffmpegDirectory: URL(fileURLWithPath: "/fake"), deno: nil),
        destination: dest, tmpDirectory: FileManager.default.temporaryDirectory,
        appSupportDirectory: FileManager.default.temporaryDirectory, runner: FakeProcessRunner())

    model.addURL(pdfURL)
    let item = model.queue.items[0]
    var waited = 0
    while item.state == .probing, waited < 2000 { waited += 1; try? await Task.sleep(for: .milliseconds(5)) }
    #expect(item.state == .readyToChoose)
    if case .directFile = item.source {} else { Issue.record("expected .directFile, got \(item.source)") }

    model.confirmDirect(item)
    waited = 0
    while item.state != .done, waited < 4000 {
        if case .failed(let message) = item.state { Issue.record("download failed: \(message)"); return }
        waited += 1
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(item.state == .done)
    #expect(item.deliveredFileURL != nil)
}
