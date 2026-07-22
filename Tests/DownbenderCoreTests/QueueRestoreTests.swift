import Testing
import Foundation
@testable import DownbenderCore

@MainActor private func makeModel(runner: ProcessRunning, appSupport: URL) -> AppModel {
    let model = AppModel(
        binaries: BundledBinaries(
            ytdlp: URL(fileURLWithPath: "/fake/yt-dlp"),
            ffmpegDirectory: URL(fileURLWithPath: "/ff"),
            deno: nil
        ),
        destination: URL(fileURLWithPath: "/tmp/dest"),
        tmpDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("qr-tmp-\(UUID().uuidString)"),
        appSupportDirectory: appSupport,
        cookiesBrowser: nil,
        runner: runner,
        directSessionFactory: { FailingURLProtocol.session() }
    )
    model.probeRetryDelay = .milliseconds(1)
    return model
}

private func freshSupportDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("qr-\(UUID().uuidString)")
}

@MainActor
@Test func restoreQueueRehydratesPersistedItemsPaused() {
    let support = freshSupportDir()
    defer { try? FileManager.default.removeItem(at: support) }
    // First launch: enqueue-ish state written straight through the store.
    let store = QueuePersistence(fileURL: support.appendingPathComponent("queue.json"))
    let active = DownloadItem(url: "https://youtu.be/a", title: "A",
                              format: .video(height: 720),
                              destination: URL(fileURLWithPath: "/tmp/dest"), state: .downloading)
    let finished = DownloadItem(url: "https://youtu.be/b", title: "B",
                                destination: URL(fileURLWithPath: "/tmp/dest"), state: .done)
    store.saveNow([active, finished])

    // Second launch.
    let model = makeModel(runner: FakeProcessRunner(), appSupport: support)
    model.restoreQueue()
    #expect(model.queue.items.count == 2)
    #expect(model.queue.items[0].state == .paused)
    #expect(model.queue.items[0].format == .video(height: 720))
    #expect(model.queue.items[1].state == .done)
}

@MainActor
@Test func queueMutationsPersistAutomatically() async {
    let support = freshSupportDir()
    defer { try? FileManager.default.removeItem(at: support) }
    let model = makeModel(runner: FakeProcessRunner(stderr: "ERROR: This video is private", exitCode: 1), appSupport: support)
    model.addURL("https://youtu.be/abc")
    var waited = 0
    let file = support.appendingPathComponent("queue.json")
    while !FileManager.default.fileExists(atPath: file.path), waited < 400 {
        waited += 1
        try? await Task.sleep(for: .milliseconds(5))
    }
    let loaded = QueuePersistence(fileURL: file).load()
    #expect(loaded.count == 1)
    #expect(loaded[0].url == "https://youtu.be/abc")
}

@MainActor
@Test func pauseAllActiveAndLiveTaskDraining() async {
    let vm = QueueViewModel(maxConcurrent: 2, perform: { item in
        do {
            try await Task.sleep(for: .seconds(5))
            item.state = .done
        } catch {
            if item.state == .downloading || item.state == .merging { item.state = .cancelled }
        }
    })
    let a = DownloadItem(url: "a", title: "a", format: .audioMP3, destination: URL(fileURLWithPath: "/tmp"))
    let b = DownloadItem(url: "b", title: "b", format: .audioMP3, destination: URL(fileURLWithPath: "/tmp"))
    let c = DownloadItem(url: "c", title: "c", format: .audioMP3, destination: URL(fileURLWithPath: "/tmp"))
    vm.enqueue(a)
    vm.enqueue(b)
    vm.enqueue(c)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(vm.hasLiveTasks)

    vm.pauseAllActive()
    var waited = 0
    while vm.hasLiveTasks, waited < 300 {
        waited += 1
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(a.state == .paused)
    #expect(b.state == .paused)
    #expect(c.state == .paused) // the queued third pauses too — it must not silently never run
    #expect(!vm.hasLiveTasks)
}

@MainActor
@Test func onMutationFiresOnQueueChanges() {
    let vm = QueueViewModel(maxConcurrent: 1, perform: { _ in })
    let counter = CallCounter()
    vm.onMutation = { _ = counter.next() }
    let item = DownloadItem(url: "u", title: "t", destination: URL(fileURLWithPath: "/tmp"), state: .readyToChoose)
    vm.add(item)
    vm.remove(item)
    #expect(counter.count >= 2)
}
