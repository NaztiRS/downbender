import Testing
import Foundation
@testable import DownbenderCore

extension DirectDownloadTests {
    @MainActor
    @Test func directDownloadRetriesTransientURLErrorAndSucceeds() async throws {
        let dest = freshDir(); let tmp = freshDir()
        defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: tmp) }
        let calls = CallCounter()
        MockURLProtocol.handler = { request in
            if calls.next() == 0 { throw URLError(.networkConnectionLost) }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("ok".utf8))
        }
        let coordinator = DirectDownloadCoordinator(service: DirectDownloadService(), maxBytes: nil,
                                                    retryDelay: .milliseconds(1),
                                                    sessionFactory: { MockURLProtocol.session() })
        let item = DownloadItem(url: "https://example.com/a.zip", title: "a.zip", destination: dest, state: .downloading)
        item.source = .directFile(DirectFileInfo(suggestedName: "a.zip"))

        await coordinator.run(item, tmpDirectory: tmp)

        #expect(item.state == .done)
        #expect(calls.count == 2)
    }

    @MainActor
    @Test func directDownloadFailsAfterThreeTransientAttempts() async {
        let dest = freshDir(); let tmp = freshDir()
        defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: tmp) }
        let calls = CallCounter()
        MockURLProtocol.handler = { _ in
            _ = calls.next()
            throw URLError(.timedOut)
        }
        let coordinator = DirectDownloadCoordinator(service: DirectDownloadService(), maxBytes: nil,
                                                    retryDelay: .milliseconds(1),
                                                    sessionFactory: { MockURLProtocol.session() })
        let item = DownloadItem(url: "https://example.com/a.zip", title: "a.zip", destination: dest, state: .downloading)
        item.source = .directFile(DirectFileInfo())

        await coordinator.run(item, tmpDirectory: tmp)

        guard case .failed = item.state else { Issue.record("expected .failed, got \(item.state)"); return }
        #expect(calls.count == 3)
    }

    @MainActor
    @Test func directDownloadDoesNotRetryPermanentErrors() async {
        let dest = freshDir(); let tmp = freshDir()
        defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: tmp) }
        let calls = CallCounter()
        MockURLProtocol.handler = { request in
            _ = calls.next()
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let coordinator = DirectDownloadCoordinator(service: DirectDownloadService(), maxBytes: nil,
                                                    retryDelay: .milliseconds(1),
                                                    sessionFactory: { MockURLProtocol.session() })
        let item = DownloadItem(url: "https://example.com/a.zip", title: "a.zip", destination: dest, state: .downloading)
        item.source = .directFile(DirectFileInfo())

        await coordinator.run(item, tmpDirectory: tmp)

        guard case .failed = item.state else { Issue.record("expected .failed, got \(item.state)"); return }
        #expect(calls.count == 1)
    }

    @MainActor
    @Test func staleStoredResumeDataStillCompletesAndClears() async throws {
        let dest = freshDir(); let tmp = freshDir()
        defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: tmp) }
        MockURLProtocol.respond(status: 200, data: Data("ok".utf8))
        let coordinator = DirectDownloadCoordinator(service: DirectDownloadService(), maxBytes: nil,
                                                    retryDelay: .milliseconds(1),
                                                    sessionFactory: { MockURLProtocol.session() })
        let item = DownloadItem(url: "https://example.com/a.zip", title: "a.zip", destination: dest, state: .downloading)
        item.source = .directFile(DirectFileInfo(suggestedName: "a.zip"))
        item.resumeData = Data("stale".utf8)

        await coordinator.run(item, tmpDirectory: tmp)

        #expect(item.state == .done)
        #expect(item.resumeData == nil)
    }

    @MainActor
    @Test func cancellingADirectItemClearsResumeDataAndMarksCancelled() async throws {
        let dest = freshDir(); let tmp = freshDir()
        defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: tmp) }
        StallingURLProtocol.stopped = false
        let coordinator = DirectDownloadCoordinator(service: DirectDownloadService(), maxBytes: nil,
                                                    retryDelay: .milliseconds(1),
                                                    sessionFactory: { StallingURLProtocol.session() })
        let item = DownloadItem(url: "https://example.com/big.zip", title: "big.zip", destination: dest, state: .downloading)
        item.source = .directFile(DirectFileInfo())

        let task = Task { await coordinator.run(item, tmpDirectory: tmp) }
        try? await Task.sleep(for: .milliseconds(150))
        task.cancel() // queue-style cancel: no state pre-set → coordinator marks .cancelled
        await task.value

        #expect(item.state == .cancelled)
        #expect(item.resumeData == nil)
    }

    @MainActor
    @Test func pausedDirectItemStaysPausedWhenInterrupted() async throws {
        let dest = freshDir(); let tmp = freshDir()
        defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: tmp) }
        StallingURLProtocol.stopped = false
        let coordinator = DirectDownloadCoordinator(service: DirectDownloadService(), maxBytes: nil,
                                                    retryDelay: .milliseconds(1),
                                                    sessionFactory: { StallingURLProtocol.session() })
        let item = DownloadItem(url: "https://example.com/big.zip", title: "big.zip", destination: dest, state: .downloading)
        item.source = .directFile(DirectFileInfo())

        let task = Task { await coordinator.run(item, tmpDirectory: tmp) }
        try? await Task.sleep(for: .milliseconds(150))
        item.state = .paused // exact order of QueueViewModel.pause
        task.cancel()
        await task.value

        #expect(item.state == .paused) // resumeData, when the server provides it, stays for resume
    }
}
