import Testing
import Foundation
@testable import DownbenderCore

private func freshFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("qp-\(UUID().uuidString)")
        .appendingPathComponent("queue.json")
}

@Test func downloadFormatRoundTripsThroughID() {
    #expect(DownloadFormat.maximumVideo.id == "vmax")
    #expect(DownloadFormat(id: "vmax") == .maximumVideo)
    #expect(DownloadFormat(id: "v1080") == .video(height: 1080))
    #expect(DownloadFormat(id: "v2160") == .video(height: 2160))
    #expect(DownloadFormat(id: "mp3") == .audioMP3)
    #expect(DownloadFormat(id: "v0") == nil)
    #expect(DownloadFormat(id: "v-1") == nil)
    #expect(DownloadFormat(id: "junk") == nil)
    #expect(DownloadFormat(id: DownloadFormat.video(height: 720).id) == .video(height: 720))
}

@Test func downloadFormatLabelsExplainResolutionAndContainer() {
    #expect(DownloadFormat.maximumVideo.label == "Maximum available")
    #expect(DownloadFormat.maximumVideo.preferenceLabel == "Maximum available")
    #expect(DownloadFormat.maximumVideo.containerLabel == "MKV")
    #expect(DownloadFormat.video(height: 2160).label == "2160p (4K)")
    #expect(DownloadFormat.video(height: 4320).label == "4320p (8K)")
    #expect(DownloadFormat.video(height: 1440).containerLabel == "MKV")
    #expect(DownloadFormat.video(height: 1080).containerLabel == "MP4")
    #expect(DownloadFormat.audioMP3.containerLabel == "MP3")
}

@MainActor
@Test func maximumVideoRoundTripsThroughVersionOneQueue() {
    let file = freshFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = QueuePersistence(fileURL: file)
    let item = DownloadItem(
        url: "https://youtu.be/maximum",
        title: "Maximum",
        format: .maximumVideo,
        destination: URL(fileURLWithPath: "/tmp/dest"),
        state: .queued
    )

    store.saveNow([item])
    let loaded = store.load()

    #expect(QueuePersistence.currentVersion == 1)
    #expect(loaded.count == 1)
    #expect(loaded[0].formatID == "vmax")
    let restored = loaded[0].makeItem()
    #expect(restored.state == .paused)
    #expect(restored.format == .maximumVideo)
}

@MainActor
@Test func saveNowThenLoadRoundTripsItems() throws {
    let file = freshFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = QueuePersistence(fileURL: file)

    let media = DownloadItem(url: "https://youtu.be/a", title: "Video A",
                             format: .video(height: 1080),
                             destination: URL(fileURLWithPath: "/tmp/dest"), state: .downloading)
    media.includeSubtitles = true
    media.fraction = 0.42
    let direct = DownloadItem(url: "https://example.com/f.zip", title: "f.zip",
                              destination: URL(fileURLWithPath: "/tmp/dest"), state: .done)
    direct.source = .directFile(DirectFileInfo(suggestedName: "f.zip", sizeBytes: 123, contentType: "application/zip"))
    direct.deliveredFileURL = URL(fileURLWithPath: "/tmp/dest/f.zip")

    store.saveNow([media, direct])
    let loaded = store.load()
    #expect(loaded.count == 2)

    let first = loaded[0].makeItem()
    #expect(first.state == .paused)               // interrupted work comes back paused
    #expect(first.format == .video(height: 1080))
    #expect(first.includeSubtitles == true)
    #expect(first.fraction == 0.42)

    let second = loaded[1].makeItem()
    #expect(second.state == .done)
    #expect(second.source == .directFile(DirectFileInfo(suggestedName: "f.zip", sizeBytes: 123, contentType: "application/zip")))
    #expect(second.deliveredFileURL?.path == "/tmp/dest/f.zip")
}

@MainActor
@Test func rehydrationMapsEveryInterruptedStateToPaused() {
    let file = freshFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = QueuePersistence(fileURL: file)
    let states: [DownloadItem.State] = [.queued, .downloading, .merging]
    let items = states.map { DownloadItem(url: "u", title: "t", destination: URL(fileURLWithPath: "/tmp"), state: $0) }
    store.saveNow(items)
    for persisted in store.load() {
        #expect(persisted.makeItem().state == .paused)
    }
}

@MainActor
@Test func failureMessagesSurviveTheRoundTrip() {
    let file = freshFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = QueuePersistence(fileURL: file)
    let failed = DownloadItem(url: "u", title: "t", destination: URL(fileURLWithPath: "/tmp"), state: .failed("boom"))
    store.saveNow([failed])
    #expect(store.load()[0].makeItem().state == .failed("boom"))
}

@MainActor
@Test func corruptOrUnknownVersionFilesYieldEmptyQueue() throws {
    let file = freshFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json at all".utf8).write(to: file)
    #expect(QueuePersistence(fileURL: file).load().isEmpty)
    try Data(#"{"version": 999, "items": []}"#.utf8).write(to: file)
    #expect(QueuePersistence(fileURL: file).load().isEmpty)
    #expect(QueuePersistence(fileURL: freshFile()).load().isEmpty)   // missing file
}

@MainActor
@Test func scheduleSaveDebouncesAndWrites() async {
    let file = freshFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = QueuePersistence(fileURL: file, debounce: .milliseconds(20))
    let item = DownloadItem(url: "u", title: "t", destination: URL(fileURLWithPath: "/tmp"), state: .queued)
    store.scheduleSave([item])
    #expect(!FileManager.default.fileExists(atPath: file.path))   // not yet — debounced
    var waited = 0
    while !FileManager.default.fileExists(atPath: file.path), waited < 200 {
        waited += 1
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(store.load().count == 1)
}
