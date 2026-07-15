import Testing
import Foundation
@testable import DownbenderCore

@Test func downloadProgressDelegateReportsFractionThenNilWhenTotalUnknown() {
    let calls = SendableBox<[Double?]>([])
    let delegate = DownloadProgressDelegate(onProgress: { calls.value.append($0) })
    let session = URLSession.shared
    let task = session.downloadTask(with: URL(string: "https://example.com/x")!)
    defer { task.cancel() }

    // Known total → 0…1 fraction.
    delegate.urlSession(session, downloadTask: task, didWriteData: 0, totalBytesWritten: 50, totalBytesExpectedToWrite: 100)
    // Unknown total (chunked / -1) → nil (indeterminate) instead of silence that freezes the bar at 0%.
    delegate.urlSession(session, downloadTask: task, didWriteData: 0, totalBytesWritten: 50, totalBytesExpectedToWrite: -1)

    #expect(calls.value == [0.5, nil])
}

@Test func downloadProgressDelegateUsesHeadSizeWhenGetHasNoTotal() {
    let calls = SendableBox<[Double?]>([])
    // A HEAD gave 200 bytes up front; the GET reports no total (-1) → still a real fraction.
    let delegate = DownloadProgressDelegate(onProgress: { calls.value.append($0) }, expectedBytes: 200)
    let session = URLSession.shared
    let task = session.downloadTask(with: URL(string: "https://example.com/x")!)
    defer { task.cancel() }

    delegate.urlSession(session, downloadTask: task, didWriteData: 0, totalBytesWritten: 100, totalBytesExpectedToWrite: -1)

    #expect(calls.value == [0.5])
}
