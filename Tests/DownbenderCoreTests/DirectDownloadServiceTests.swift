import Testing
import Foundation
@testable import DownbenderCore

/// Fresh scratch directory for a download test (no shared state).
func freshDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dbtest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// All tests that drive MockURLProtocol live in ONE serialized suite: the mock's response
/// handler is process-global, so parallel tests would clobber each other's canned response.
/// Later tasks (coordinator, disk guard) add their MockURLProtocol tests to this suite via
/// `extension DirectDownloadTests` so they stay serialized with these.
@Suite(.serialized)
struct DirectDownloadTests {
    @Test func writesFileAndReportsProgress() async throws {
        let dest = freshDir(); let tmp = freshDir()
        defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: tmp) }
        MockURLProtocol.respond(status: 200, data: Data("hello world".utf8),
                                headers: ["Content-Length": "11", "Content-Type": "application/zip"])
        let service = DirectDownloadService()
        let delivered = try await service.download(
            url: "https://example.com/a.zip", destination: dest, tmpDirectory: tmp,
            suggestedName: nil, maxBytes: nil, session: MockURLProtocol.session(), onProgress: { _ in }
        )
        #expect(delivered.lastPathComponent == "a.zip")
        #expect(FileManager.default.fileExists(atPath: delivered.path))
        #expect(try String(contentsOf: delivered, encoding: .utf8) == "hello world")
    }

    @Test func throwsAccessDeniedOn403() async throws {
        let dest = freshDir(); let tmp = freshDir()
        defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: tmp) }
        MockURLProtocol.respond(status: 403, data: Data())
        let service = DirectDownloadService()
        await #expect(throws: DirectDownloadError.accessDenied) {
            _ = try await service.download(url: "https://example.com/a.zip", destination: dest, tmpDirectory: tmp,
                                           suggestedName: nil, maxBytes: nil, session: MockURLProtocol.session(), onProgress: { _ in })
        }
    }

    @Test func safeFileNameStripsTraversalAndSeparators() {
        #expect(DirectDownloadService.safeFileName("../../etc/passwd") == "passwd")
        #expect(DirectDownloadService.safeFileName("/abs/evil.sh") == "evil.sh")
        #expect(DirectDownloadService.safeFileName("na\u{0000}me.zip") == "name.zip")
        #expect(DirectDownloadService.safeFileName("a%2Fb.zip") == "b.zip")
        #expect(DirectDownloadService.safeFileName("..") == "download")
        #expect(DirectDownloadService.safeFileName("") == "download")
    }

    @Test func doesNotOverwriteExistingFile() async throws {
        let dest = freshDir(); let tmp = freshDir()
        defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: tmp) }
        FileManager.default.createFile(atPath: dest.appendingPathComponent("a.zip").path, contents: Data("old".utf8))
        MockURLProtocol.respond(status: 200, data: Data("new".utf8), headers: ["Content-Type": "application/zip"])
        let delivered = try await DirectDownloadService().download(
            url: "https://example.com/a.zip", destination: dest, tmpDirectory: tmp,
            session: MockURLProtocol.session(), onProgress: { _ in })
        #expect(delivered.lastPathComponent == "a (1).zip")
        #expect(try String(contentsOf: dest.appendingPathComponent("a.zip"), encoding: .utf8) == "old")
    }

    @Test func sanitizesMaliciousServerFilename() async throws {
        let dest = freshDir(); let tmp = freshDir()
        defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: tmp) }
        MockURLProtocol.respond(status: 200, data: Data("x".utf8),
                                headers: ["Content-Disposition": #"attachment; filename="../../../../tmp/pwned.sh""#])
        let delivered = try await DirectDownloadService().download(
            url: "https://example.com/dl", destination: dest, tmpDirectory: tmp,
            session: MockURLProtocol.session(), onProgress: { _ in })
        #expect(delivered.deletingLastPathComponent().standardizedFileURL.path == dest.standardizedFileURL.path)
        #expect(delivered.lastPathComponent == "pwned.sh")
    }
}
