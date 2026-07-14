import Foundation
@testable import DownbenderCore

/// Serves canned responses for URLSession tests. Set `handler` per test.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    // These are URLProtocol class-method overrides; `static` can't override a `class func`.
    // swiftlint:disable static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    // swiftlint:enable static_over_final_class
    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return DirectDownloadService.makeSession(configuration: config)
    }
    static func respond(status: Int, data: Data, headers: [String: String] = [:]) {
        handler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (response, data)
        }
    }
}
