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

@Test func appDownloadProgressLeavesRoomForExtractionAndInstall() {
    #expect(AppSelfUpdater.overallProgress(forDownloadFraction: nil) == nil)
    #expect(AppSelfUpdater.overallProgress(forDownloadFraction: 0) == 0)
    #expect(AppSelfUpdater.overallProgress(forDownloadFraction: 0.5) == 0.45)
    #expect(AppSelfUpdater.overallProgress(forDownloadFraction: 1) == 0.9)
    #expect(AppSelfUpdater.overallProgress(forDownloadFraction: 2) == 0.9)
}

@Test func visibleUpdateProgressIsClampedAndNeverMovesBackward() {
    #expect(UnifiedUpdater.advancingProgress(current: 0, reported: nil) == nil)
    #expect(UnifiedUpdater.advancingProgress(current: nil, reported: 0.2) == 0.2)
    #expect(UnifiedUpdater.advancingProgress(current: 0.6, reported: 0.4) == 0.6)
    #expect(UnifiedUpdater.advancingProgress(current: 0.6, reported: 2) == 1)
    #expect(UnifiedUpdater.advancingProgress(current: 0.6, reported: nil) == 0.6)
}
