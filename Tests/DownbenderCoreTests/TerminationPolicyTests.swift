import Testing
import Foundation
@testable import DownbenderCore

@MainActor
@Test func interruptedCountCountsOnlyWorkAQuitWouldLose() {
    func item(_ state: DownloadItem.State) -> DownloadItem {
        DownloadItem(url: "u", title: "t", destination: URL(fileURLWithPath: "/tmp"), state: state)
    }
    let items = [
        item(.downloading), item(.merging), item(.queued), // counted
        item(.done), item(.paused), item(.failed("x")), // not counted
        item(.cancelled), item(.readyToChoose), item(.probing), // not counted
    ]
    #expect(TerminationPolicy.interruptedCount(items) == 3)
    #expect(TerminationPolicy.interruptedCount([]) == 0)
}
