import Foundation
import Testing
@testable import DownbenderCore

@MainActor
private func reorderItem(
    _ title: String,
    state: DownloadItem.State = .queued
) -> DownloadItem {
    DownloadItem(
        url: "https://example.com/\(title)",
        title: title,
        format: .audioMP3,
        destination: URL(fileURLWithPath: "/tmp"),
        state: state
    )
}

@MainActor
private func titles(in queue: QueueViewModel) -> [String] {
    queue.items.map(\.title)
}

@MainActor
private final class ReorderExecutionProbe {
    var holdFirst = true
    var startOrder: [String] = []
}

@MainActor
@Test func queueMoveUsesSwiftUIOffsetsAndNotifiesOnlyForAChange() {
    let queue = QueueViewModel(maxConcurrent: 0, perform: { _ in })
    for title in ["A", "B", "C", "D", "E"] {
        queue.add(reorderItem(title))
    }

    var mutations = 0
    queue.onMutation = { mutations += 1 }

    #expect(queue.move(fromOffsets: IndexSet([1, 3]), toOffset: 5))
    #expect(titles(in: queue) == ["A", "C", "E", "B", "D"])
    #expect(mutations == 1)

    #expect(!queue.move(fromOffsets: IndexSet(integer: 0), toOffset: 1))
    #expect(titles(in: queue) == ["A", "C", "E", "B", "D"])
    #expect(mutations == 1)
}

@MainActor
@Test func queueMoveRejectsActiveAndInvalidMovesAtomically() {
    let queue = QueueViewModel(maxConcurrent: 0, perform: { _ in })
    let queued = reorderItem("queued")
    let active = reorderItem("active", state: .downloading)
    let paused = reorderItem("paused", state: .paused)
    queue.add(queued)
    queue.add(active)
    queue.add(paused)

    var mutations = 0
    queue.onMutation = { mutations += 1 }

    #expect(queue.canReorder(queued))
    #expect(!queue.canReorder(active))
    #expect(queue.canReorder(paused))

    #expect(!queue.move(fromOffsets: IndexSet(integer: 1), toOffset: 0))
    #expect(!queue.move(fromOffsets: IndexSet([0, 1]), toOffset: 3))
    #expect(!queue.move(fromOffsets: IndexSet(integer: 9), toOffset: 0))
    #expect(!queue.move(fromOffsets: IndexSet(integer: 0), toOffset: 9))
    #expect(titles(in: queue) == ["queued", "active", "paused"])
    #expect(mutations == 0)
}

@MainActor
@Test func pumpStartsWaitingItemsInTheirReorderedPriority() async {
    let probe = ReorderExecutionProbe()
    let queue = QueueViewModel(maxConcurrent: 1, perform: { item in
        probe.startOrder.append(item.title)
        if item.title == "A" {
            while probe.holdFirst {
                await Task.yield()
            }
        }
        item.state = .done
    })

    let first = reorderItem("A")
    let second = reorderItem("B")
    let promoted = reorderItem("C")
    queue.enqueue(first)
    queue.enqueue(second)
    queue.enqueue(promoted)

    #expect(first.state == .downloading)
    #expect(second.state == .queued)
    #expect(promoted.state == .queued)
    #expect(queue.move(fromOffsets: IndexSet(integer: 2), toOffset: 1))
    #expect(titles(in: queue) == ["A", "C", "B"])

    probe.holdFirst = false
    var attempts = 0
    while queue.items.contains(where: { $0.state != .done }), attempts < 500 {
        attempts += 1
        try? await Task.sleep(for: .milliseconds(2))
    }

    #expect(probe.startOrder == ["A", "C", "B"])
    #expect(queue.items.allSatisfy { $0.state == .done })
}
