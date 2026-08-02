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

    for bytesWritten in [20, 80, 140, 200] {
        delegate.urlSession(
            session,
            downloadTask: task,
            didWriteData: 0,
            totalBytesWritten: Int64(bytesWritten),
            totalBytesExpectedToWrite: -1
        )
    }

    #expect(calls.value == [0.1, 0.4, 0.7, 1])
}

@MainActor @Test func manualDownloadBridgeReceivesProgressAndPreservesTheDownloadedFile() async throws {
    let (chunks, feeder) = AsyncStream<Data>.makeStream()
    UpdaterProgressURLProtocol.chunks = chunks
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UpdaterProgressURLProtocol.self]
    let session = URLSession(configuration: configuration)
    var downloadedFile: URL?
    defer {
        feeder.finish()
        UpdaterProgressURLProtocol.chunks = nil
        session.invalidateAndCancel()
        if let downloadedFile { try? FileManager.default.removeItem(at: downloadedFile) }
    }

    let calls = SendableBox<[Double?]>([])
    let delegate = DownloadProgressDelegate(
        onProgress: { calls.value.append($0) },
        expectedBytes: Int64(UpdaterProgressURLProtocol.totalBytes),
        temporaryFileExtension: "zip"
    )
    let operation = Task {
        try await delegate.download(
            session: session,
            from: URL(string: "https://updates.downbender.test/Downbender.zip")!
        )
    }

    feeder.yield(Data(repeating: 0x11, count: UpdaterProgressURLProtocol.chunkSize))
    let first = await waitForProgress(calls, atLeast: 1.0 / 3.0)
    #expect(first != nil)
    #expect(first.map { $0 < 1 } == true)

    feeder.yield(Data(repeating: 0x22, count: UpdaterProgressURLProtocol.chunkSize))
    let second = await waitForProgress(calls, atLeast: 2.0 / 3.0)
    #expect(second != nil)
    #expect(second.map { $0 < 1 } == true)

    feeder.yield(Data(repeating: 0x33, count: UpdaterProgressURLProtocol.chunkSize))
    feeder.finish()
    let (downloaded, response) = try await operation.value
    downloadedFile = downloaded

    let fractions = calls.value.compactMap { $0 }
    #expect(!fractions.isEmpty)
    #expect(fractions.contains { $0 > 0 && $0 < 1 })
    #expect(fractions.last == 1)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(downloaded.pathExtension == "zip")
    #expect(try Data(contentsOf: downloaded).count == UpdaterProgressURLProtocol.totalBytes)
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

/// A real URLSession transport is important here: calling the delegate methods directly cannot
/// detect the Foundation convenience-API bug that originally swallowed every progress callback.
private final class UpdaterProgressURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var chunks: AsyncStream<Data>?
    static let chunkSize = 2 * 1024 * 1024
    static let chunkCount = 3
    static let totalBytes = chunkSize * chunkCount
    private let lock = NSLock()
    private var worker: Task<Void, Never>?

    // These are URLProtocol class-method overrides; `static` can't override a `class func`.
    // swiftlint:disable static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    // swiftlint:enable static_over_final_class

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(Self.totalBytes)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard let chunks = Self.chunks else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let callbacks = UpdaterProgressCallbacks(owner: self)
        let worker = Task {
            for await chunk in chunks {
                guard !Task.isCancelled else { return }
                callbacks.didLoad(chunk)
            }
            guard !Task.isCancelled else { return }
            callbacks.didFinish()
        }
        lock.lock()
        self.worker = worker
        lock.unlock()
    }

    override func stopLoading() {
        lock.lock()
        let worker = self.worker
        self.worker = nil
        lock.unlock()
        worker?.cancel()
    }
}

private final class UpdaterProgressCallbacks: @unchecked Sendable {
    private weak var owner: UpdaterProgressURLProtocol?

    init(owner: UpdaterProgressURLProtocol) {
        self.owner = owner
    }

    func didLoad(_ data: Data) {
        guard let owner else { return }
        owner.client?.urlProtocol(owner, didLoad: data)
    }

    func didFinish() {
        guard let owner else { return }
        owner.client?.urlProtocolDidFinishLoading(owner)
    }
}

private func waitForProgress(_ calls: SendableBox<[Double?]>, atLeast target: Double) async -> Double? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if let latest = calls.value.compactMap({ $0 }).last, latest + 0.0001 >= target {
            return latest
        }
        await Task.yield()
    }
    return calls.value.compactMap { $0 }.last
}
