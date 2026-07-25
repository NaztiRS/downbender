import Testing
import Foundation
@testable import DownbenderCore

private enum RedirectTestAction {
    case redirect(URL)
    case respond(Data)
}

/// Emits real URL Loading System redirect events. When the task delegate rejects a hop,
/// URLSession leaves this protocol instance alive, so it completes with the original 302 body.
private final class RedirectURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> RedirectTestAction)?

    private let lock = NSLock()
    private var stopped = false

    // swiftlint:disable static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    // swiftlint:enable static_over_final_class

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch handler(request) {
        case .redirect(let target):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": target.absoluteString]
            )!
            var redirected = URLRequest(url: target)
            redirected.httpMethod = request.httpMethod
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)

            // If the delegate follows, URLSession calls stopLoading and creates another protocol
            // instance. If it rejects, complete this request so the task can surface our policy error.
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self] in
                guard let self, !self.isStopped else { return }
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: Data())
                self.client?.urlProtocolDidFinishLoading(self)
            }
        case .respond(let data):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": String(data.count)]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectURLProtocol.self]
        return DirectDownloadService.makeSession(configuration: configuration)
    }
}

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

    @Test func rejectsFileOverMaxBytes() async throws {
        let dest = freshDir(); let tmp = freshDir()
        defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: tmp) }
        MockURLProtocol.respond(status: 200, data: Data(count: 5000),
                                headers: ["Content-Length": "5000", "Content-Type": "application/zip"])
        await #expect(throws: DirectDownloadError.fileTooLarge(1000)) {
            _ = try await DirectDownloadService().download(url: "https://example.com/a.zip", destination: dest, tmpDirectory: tmp,
                                                           maxBytes: 1000, session: MockURLProtocol.session(), onProgress: { _ in })
        }
    }

    @Test func setsQuarantineXattr() async throws {
        let dest = freshDir(); let tmp = freshDir()
        defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: tmp) }
        MockURLProtocol.respond(status: 200, data: Data("x".utf8), headers: ["Content-Type": "application/zip"])
        let delivered = try await DirectDownloadService().download(
            url: "https://example.com/a.zip", destination: dest, tmpDirectory: tmp,
            session: MockURLProtocol.session(), onProgress: { _ in })
        #expect(DirectDownloadService.isQuarantined(delivered))
    }

    @Test func headInfoReadsSizeNameAndType() async throws {
        MockURLProtocol.handler = { req in
            let r = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Length": "2048", "Content-Type": "application/pdf",
                                                   "Content-Disposition": #"attachment; filename="report.pdf""#])!
            return (r, Data())
        }
        let info = try await DirectDownloadService().headInfo(url: "https://example.com/dl", session: MockURLProtocol.session())
        #expect(info.sizeBytes == 2048)
        #expect(info.contentType == "application/pdf")
        #expect(info.suggestedName == "report.pdf")
    }

    @Test func downloadRejectsInsecureHTTPByDefault() async throws {
        let dest = freshDir(); let tmp = freshDir()
        defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: tmp) }
        await #expect(throws: DirectDownloadError.insecureScheme) {
            _ = try await DirectDownloadService().download(url: "http://example.com/a.zip", destination: dest, tmpDirectory: tmp,
                                                           session: MockURLProtocol.session(), onProgress: { _ in })
        }
    }

    @Test func allowsInsecureHTTPWhenExplicitlyAllowed() async throws {
        let dest = freshDir(); let tmp = freshDir()
        defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: tmp) }
        MockURLProtocol.respond(status: 200, data: Data("x".utf8), headers: ["Content-Type": "application/zip"])
        let delivered = try await DirectDownloadService().download(
            url: "http://example.com/a.zip", destination: dest, tmpDirectory: tmp,
            allowInsecureHTTP: true, session: MockURLProtocol.session(), onProgress: { _ in })
        #expect(delivered.lastPathComponent == "a.zip")
    }

    @Test func redirectGuardRejectsHTTPSDowngrade() {
        let guardPolicy = DirectRedirectGuard(permitsHTTPRedirects: false, maximumRedirects: 10)
        let source = HTTPURLResponse(
            url: URL(string: "https://example.com/start")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        )!
        let target = URLRequest(url: URL(string: "http://example.com/file.zip")!)

        #expect(guardPolicy.requestToFollow(target, from: source) == nil)
        #expect(guardPolicy.rejection == .insecureScheme)
    }

    @Test func redirectGuardAllowsHTTPSAndNeverDowngradesAfterAnUpgrade() {
        let secure = DirectRedirectGuard(permitsHTTPRedirects: false, maximumRedirects: 10)
        let httpsSource = HTTPURLResponse(
            url: URL(string: "https://example.com/start")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        )!
        let httpsTarget = URLRequest(url: URL(string: "https://cdn.example.com/file.zip")!)
        #expect(secure.requestToFollow(httpsTarget, from: httpsSource) == httpsTarget)

        let confirmedHTTP = DirectRedirectGuard(permitsHTTPRedirects: true, maximumRedirects: 10)
        let httpSource = HTTPURLResponse(
            url: URL(string: "http://example.com/start")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        )!
        #expect(confirmedHTTP.requestToFollow(httpsTarget, from: httpSource) == httpsTarget)

        let downgrade = URLRequest(url: URL(string: "http://cdn.example.com/file.zip")!)
        #expect(confirmedHTTP.requestToFollow(downgrade, from: httpsSource) == nil)
        #expect(confirmedHTTP.rejection == .insecureScheme)
    }

    @Test func redirectGuardAllowsTenHopsAndRejectsTheEleventh() {
        let guardPolicy = DirectRedirectGuard(permitsHTTPRedirects: false, maximumRedirects: 10)
        for hop in 0..<10 {
            let source = HTTPURLResponse(
                url: URL(string: "https://example.com/\(hop)")!,
                statusCode: 302,
                httpVersion: nil,
                headerFields: nil
            )!
            let target = URLRequest(url: URL(string: "https://example.com/\(hop + 1)")!)
            #expect(guardPolicy.requestToFollow(target, from: source) == target)
        }
        let source = HTTPURLResponse(
            url: URL(string: "https://example.com/10")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        )!
        let target = URLRequest(url: URL(string: "https://example.com/11")!)
        #expect(guardPolicy.requestToFollow(target, from: source) == nil)
        #expect(guardPolicy.rejection == .tooManyRedirects)
    }

    @Test func resumePreflightRejectsEmbeddedPlaintextURLForHTTPSItem() {
        #expect(DirectRedirectGuard.permitsTransfer(
            to: URL(string: "https://cdn.example.com/file.zip"),
            permitsHTTPRedirects: false
        ))
        #expect(!DirectRedirectGuard.permitsTransfer(
            to: URL(string: "http://cdn.example.com/file.zip"),
            permitsHTTPRedirects: false
        ))
        #expect(DirectRedirectGuard.permitsTransfer(
            to: URL(string: "http://cdn.example.com/file.zip"),
            permitsHTTPRedirects: true
        ))
        #expect(!DirectRedirectGuard.permitsTransfer(
            to: URL(string: "file:///tmp/file.zip"),
            permitsHTTPRedirects: true
        ))
    }

    @Test func downloadRejectsAnInsecureFinalResponseAsDefenseInDepth() async throws {
        let dest = freshDir(); let tmp = freshDir()
        defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: tmp) }
        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "http://example.com/file.zip")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "8"]
            )!
            return (response, Data("insecure".utf8))
        }

        await #expect(throws: DirectDownloadError.insecureScheme) {
            _ = try await DirectDownloadService().download(
                url: "https://example.com/start",
                destination: dest,
                tmpDirectory: tmp,
                session: MockURLProtocol.session(),
                onProgress: { _ in }
            )
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: tmp.path)).isEmpty)
    }

    @Test func headInfoRejectsInitialAndFinalInsecureTransport() async {
        await #expect(throws: DirectDownloadError.insecureScheme) {
            _ = try await DirectDownloadService().headInfo(
                url: "http://example.com/file.zip",
                session: MockURLProtocol.session()
            )
        }

        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "http://example.com/file.zip")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        await #expect(throws: DirectDownloadError.insecureScheme) {
            _ = try await DirectDownloadService().headInfo(
                url: "https://example.com/start",
                session: MockURLProtocol.session()
            )
        }
    }

    @Test func URLSessionDelegateRejectsRealHTTPSDowngrade() async throws {
        let dest = freshDir(); let tmp = freshDir()
        defer {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.removeItem(at: tmp)
            RedirectURLProtocol.handler = nil
        }
        RedirectURLProtocol.handler = { request in
            request.url?.scheme == "https"
                ? .redirect(URL(string: "http://example.com/file.zip")!)
                : .respond(Data("must not download".utf8))
        }

        await #expect(throws: DirectDownloadError.insecureScheme) {
            _ = try await DirectDownloadService().download(
                url: "https://example.com/start",
                destination: dest,
                tmpDirectory: tmp,
                session: RedirectURLProtocol.session(),
                onProgress: { _ in }
            )
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: tmp.path)).isEmpty)
    }

    @Test func URLSessionDelegateFollowsRealHTTPSRedirect() async throws {
        let dest = freshDir(); let tmp = freshDir()
        defer {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.removeItem(at: tmp)
            RedirectURLProtocol.handler = nil
        }
        RedirectURLProtocol.handler = { request in
            request.url?.path == "/start"
                ? .redirect(URL(string: "https://cdn.example.com/file.zip")!)
                : .respond(Data("safe".utf8))
        }

        let delivered = try await DirectDownloadService().download(
            url: "https://example.com/start",
            destination: dest,
            tmpDirectory: tmp,
            suggestedName: "file.zip",
            session: RedirectURLProtocol.session(),
            onProgress: { _ in }
        )
        #expect(try String(contentsOf: delivered, encoding: .utf8) == "safe")
    }

    @Test func URLSessionDelegateStopsAtRedirectLimit() async throws {
        let dest = freshDir(); let tmp = freshDir()
        defer {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.removeItem(at: tmp)
            RedirectURLProtocol.handler = nil
        }
        RedirectURLProtocol.handler = { request in
            let hop = Int(request.url?.lastPathComponent ?? "0") ?? 0
            return .redirect(URL(string: "https://example.com/\(hop + 1)")!)
        }

        await #expect(throws: DirectDownloadError.tooManyRedirects) {
            _ = try await DirectDownloadService().download(
                url: "https://example.com/0",
                destination: dest,
                tmpDirectory: tmp,
                session: RedirectURLProtocol.session(),
                onProgress: { _ in }
            )
        }
    }

    @Test func headDelegateRejectsRealHTTPSDowngrade() async {
        defer { RedirectURLProtocol.handler = nil }
        RedirectURLProtocol.handler = { request in
            request.url?.scheme == "https"
                ? .redirect(URL(string: "http://example.com/file.zip")!)
                : .respond(Data())
        }

        await #expect(throws: DirectDownloadError.insecureScheme) {
            _ = try await DirectDownloadService().headInfo(
                url: "https://example.com/start",
                session: RedirectURLProtocol.session()
            )
        }
    }

}
