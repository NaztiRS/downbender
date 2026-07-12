import Testing
import Foundation
@testable import DownbenderCore

@MainActor
@Test func queueRespectsMaxConcurrencyAndCompletes() async {
    var current = 0
    var maxSeen = 0

    let vm = QueueViewModel(maxConcurrent: 2, perform: { item in
        current += 1; maxSeen = max(maxSeen, current)
        try? await Task.sleep(for: .milliseconds(30))
        current -= 1
        item.state = .done
    })

    for i in 0..<5 {
        vm.enqueue(DownloadItem(url: "u\(i)", title: "t\(i)", format: .audioMP3, destination: URL(fileURLWithPath: "/tmp")))
    }

    while vm.items.contains(where: { $0.state == .queued || $0.state == .downloading }) {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(maxSeen <= 2)
    #expect(vm.items.allSatisfy { $0.state == .done })
}
