import Testing
import Foundation
@testable import DownbenderCore

// Added to the serialized DirectDownloadTests suite: these also drive the process-global mock.
extension DirectDownloadTests {
    @MainActor
    @Test func directCoordinatorDownloadsAndMarksDone() async throws {
        let dest = freshDir(); let tmp = freshDir()
        defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: tmp) }
        MockURLProtocol.respond(status: 200, data: Data("hi".utf8), headers: ["Content-Type": "application/zip"])
        let coordinator = DirectDownloadCoordinator(service: DirectDownloadService(), maxBytes: nil,
                                                    sessionFactory: { MockURLProtocol.session() })
        let item = DownloadItem(url: "https://example.com/a.zip", title: "a.zip", destination: dest, state: .downloading)
        item.source = .directFile(DirectFileInfo(suggestedName: "a.zip"))

        await coordinator.run(item, tmpDirectory: tmp)

        #expect(item.state == .done)
        #expect(item.deliveredFileURL?.lastPathComponent == "a.zip")
    }

    @MainActor
    @Test func directCoordinatorMarksFailedOnAccessDenied() async throws {
        let dest = freshDir()
        defer { try? FileManager.default.removeItem(at: dest) }
        MockURLProtocol.respond(status: 403, data: Data())
        let coordinator = DirectDownloadCoordinator(service: DirectDownloadService(), maxBytes: nil,
                                                    sessionFactory: { MockURLProtocol.session() })
        let item = DownloadItem(url: "https://example.com/a.zip", title: "a.zip", destination: dest, state: .downloading)
        item.source = .directFile(DirectFileInfo())

        await coordinator.run(item, tmpDirectory: dest)
        guard case .failed(let msg) = item.state else { Issue.record("expected .failed"); return }
        #expect(msg.contains("Access denied"))
    }

    @MainActor
    @Test func directCoordinatorFailsWhenKnownSizeExceedsFreeSpace() async throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("dc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }

        let coordinator = DirectDownloadCoordinator(service: DirectDownloadService(), maxBytes: nil,
                                                    sessionFactory: { MockURLProtocol.session() })
        let item = DownloadItem(url: "https://example.com/huge.zip", title: "huge.zip", destination: dest, state: .downloading)
        item.source = .directFile(DirectFileInfo(suggestedName: "huge.zip", sizeBytes: Int64.max))

        await coordinator.run(item, tmpDirectory: dest)
        guard case .failed(let msg) = item.state else { Issue.record("expected .failed"); return }
        #expect(msg.contains("free space"))
    }
}
