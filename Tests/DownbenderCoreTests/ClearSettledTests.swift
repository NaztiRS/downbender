import Testing
import Foundation
@testable import DownbenderCore

@MainActor private func item(_ state: DownloadItem.State) -> DownloadItem {
    DownloadItem(url: "u", title: "t", destination: URL(fileURLWithPath: "/tmp"), state: state)
}

@MainActor
@Test func clearSettledRemovesOnlySettledStates() {
    let vm = QueueViewModel(maxConcurrent: 1, perform: { _ in })
    let keep: [DownloadItem] = [item(.probing), item(.readyToChoose), item(.queued), item(.paused)]
    let settled: [DownloadItem] = [item(.done), item(.failed("boom")), item(.cancelled)]
    for entry in keep + settled { vm.add(entry) }
    #expect(vm.hasSettledItems)

    vm.clearSettled()

    #expect(vm.items.count == keep.count)
    #expect(vm.items.allSatisfy { entry in keep.contains(where: { $0.id == entry.id }) })
    #expect(!vm.hasSettledItems)
}

@MainActor
@Test func clearSettledFiresOnMutationOnlyWhenSomethingChanges() {
    let vm = QueueViewModel(maxConcurrent: 1, perform: { _ in })
    vm.add(item(.done))
    let counter = CallCounter()
    vm.onMutation = { _ = counter.next() }

    vm.clearSettled()
    #expect(counter.count == 1)

    vm.clearSettled() // nothing settled left → no extra mutation
    #expect(counter.count == 1)
}
