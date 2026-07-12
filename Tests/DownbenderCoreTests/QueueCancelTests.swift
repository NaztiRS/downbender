import Testing
import Foundation
@testable import DownbenderCore

@MainActor
@Test func cancellingItemMarksItCancelled() async {
    let vm = QueueViewModel(maxConcurrent: 1, perform: { item in
        do {
            try await Task.sleep(for: .seconds(5))
            item.state = .done
        } catch {
            item.state = .cancelled
        }
    })
    let item = DownloadItem(url: "u", title: "t", format: .audioMP3, destination: URL(fileURLWithPath: "/tmp"))
    vm.enqueue(item)
    try? await Task.sleep(for: .milliseconds(80))
    vm.cancel(item)
    while item.state == .downloading { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(item.state == .cancelled)
}

@MainActor
@Test func cancellingQueuedItemMarksItCancelledWithoutRunning() async {
    let vm = QueueViewModel(maxConcurrent: 1, perform: { item in
        do {
            try await Task.sleep(for: .milliseconds(150))
            item.state = .done
        } catch {
            item.state = .cancelled
        }
    })
    let first = DownloadItem(url: "u1", title: "t1", format: .audioMP3, destination: URL(fileURLWithPath: "/tmp"))
    let second = DownloadItem(url: "u2", title: "t2", format: .audioMP3, destination: URL(fileURLWithPath: "/tmp"))
    vm.enqueue(first)
    vm.enqueue(second)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(second.state == .queued)
    vm.cancel(second)
    while first.state == .downloading { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(first.state == .done)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(second.state == .cancelled)
}
