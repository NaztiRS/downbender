import Testing
import Foundation
@testable import DownbenderCore

/// Sends headers + a chunk and never finishes; `stopLoading` records the teardown.
final class StallingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var stopped = false
    // swiftlint:disable static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    // swiftlint:enable static_over_final_class
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Length": "1000000"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 7, count: 1024))
        // never finishes
    }

    override func stopLoading() { Self.stopped = true }
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StallingURLProtocol.self]
        return DirectDownloadService.makeSession(configuration: config)
    }
}

extension DirectDownloadTests {
    @Test func cancellingADirectDownloadTearsTheTransferDown() async throws {
        let dest = freshDir(); let tmp = freshDir()
        defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: tmp) }
        StallingURLProtocol.stopped = false
        let task = Task {
            try await DirectDownloadService().download(
                url: "https://example.com/big.zip", destination: dest, tmpDirectory: tmp,
                session: StallingURLProtocol.session(), onProgress: { _ in }
            )
        }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
        var waited = 0
        while !StallingURLProtocol.stopped, waited < 300 {
            waited += 1
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(StallingURLProtocol.stopped)
    }

    @Test func staleResumeDataFallsBackToAFreshDownload() async throws {
        let dest = freshDir(); let tmp = freshDir()
        defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: tmp) }
        MockURLProtocol.respond(status: 200, data: Data("fresh".utf8), headers: ["Content-Type": "application/zip"])
        let delivered = try await DirectDownloadService().download(
            url: "https://example.com/a.zip", destination: dest, tmpDirectory: tmp,
            suggestedName: "a.zip", resumeData: Data("garbage-not-resume-data".utf8),
            session: MockURLProtocol.session(), onProgress: { _ in }
        )
        #expect(delivered.lastPathComponent == "a.zip")
        #expect(try Data(contentsOf: delivered) == Data("fresh".utf8))
    }

    @Test func errorResponsesLeaveNoTemporaryBehind() async throws {
        let dest = freshDir(); let tmp = freshDir()
        defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: tmp) }
        MockURLProtocol.respond(status: 403, data: Data("denied body".utf8))
        do {
            _ = try await DirectDownloadService().download(
                url: "https://example.com/a.zip", destination: dest, tmpDirectory: tmp,
                session: MockURLProtocol.session(), onProgress: { _ in }
            )
            Issue.record("expected accessDenied")
        } catch let error as DirectDownloadError {
            #expect(error == .accessDenied)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func unknownTotalReportsIndeterminateProgress() {
        let captured = SendableBox<DownloadProgress?>(nil)
        let executor = DirectDownloadExecutor(
            tmpDirectory: FileManager.default.temporaryDirectory,
            onProgress: { captured.value = $0 }, onResumeData: nil
        )
        let dummyTask = URLSession.shared.downloadTask(with: URL(string: "https://example.com/x")!)
        executor.urlSession(URLSession.shared, downloadTask: dummyTask,
                            didWriteData: 512, totalBytesWritten: 512, totalBytesExpectedToWrite: -1)
        #expect(captured.value?.totalBytes == nil)
        #expect(captured.value?.downloadedBytes == 512)
    }
}
