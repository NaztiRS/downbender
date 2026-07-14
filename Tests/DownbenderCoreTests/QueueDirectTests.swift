import Testing
import Foundation
@testable import DownbenderCore

@MainActor
@Test func startDirectQueuesFormatlessItemWithoutDuplicating() async {
    let vm = QueueViewModel(maxConcurrent: 1, perform: { item in item.state = .done })
    let item = DownloadItem(url: "https://example.com/a.zip", title: "a.zip",
                            destination: URL(fileURLWithPath: "/tmp"), state: .readyToChoose)
    item.source = .directFile(DirectFileInfo(suggestedName: "a.zip"))
    vm.add(item) // added at detection time, as AppModel does
    #expect(vm.items.count == 1)

    vm.startDirect(item)
    #expect(vm.items.count == 1) // reactivated in place — NOT re-appended
    while item.state != .done { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(item.state == .done)
}

@MainActor
@Test func startDirectIgnoresItemsNotReadyToChoose() {
    let vm = QueueViewModel(maxConcurrent: 1, perform: { _ in })
    let item = DownloadItem(url: "u", title: "t", destination: URL(fileURLWithPath: "/tmp"), state: .queued)
    vm.add(item)
    vm.startDirect(item) // no-op: wrong state
    #expect(item.state == .queued)
}
