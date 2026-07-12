import Testing
@testable import DownbenderCore

@Suite struct DownbenderCoreTests {
    @Test func versionIsSet() {
        #expect(!Downbender.version.isEmpty)
    }
}
