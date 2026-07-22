import Testing
import Foundation
@testable import DownbenderCore

@Test func transientMessagesAreClassified() {
    #expect(TransientFailure.isTransientMessage("ERROR: HTTP Error 403: Forbidden"))
    #expect(TransientFailure.isTransientMessage("Failed to resolve 'rr3---sn-x.googlevideo.com'"))
    #expect(TransientFailure.isTransientMessage("nodename nor servname provided"))
    #expect(TransientFailure.isTransientMessage("Temporary failure in name resolution"))
    #expect(TransientFailure.isTransientMessage("getaddrinfo failed"))
    #expect(!TransientFailure.isTransientMessage("ERROR: This video is private"))
    #expect(!TransientFailure.isTransientMessage("Unsupported URL"))
}

@Test func transientURLErrorsAreClassified() {
    #expect(TransientFailure.isTransient(URLError(.timedOut)))
    #expect(TransientFailure.isTransient(URLError(.networkConnectionLost)))
    #expect(TransientFailure.isTransient(URLError(.dnsLookupFailed)))
    #expect(!TransientFailure.isTransient(URLError(.badURL)))
    #expect(!TransientFailure.isTransient(URLError(.cancelled)))
}
