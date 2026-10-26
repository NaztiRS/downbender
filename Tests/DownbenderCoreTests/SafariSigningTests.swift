import Foundation
import Testing
@testable import DownbenderCore

private let developmentSHA1 = "0123456789ABCDEF0123456789ABCDEF01234567"
private let otherDevelopmentSHA1 = "89ABCDEF0123456789ABCDEF0123456789ABCDEF"
private let developmentLine = "  1) \(developmentSHA1) \"Apple Development: dev@example.com (AAAAAAAAAA)\""
private let otherDevelopmentLine = "  2) \(otherDevelopmentSHA1) \"Apple Development: other@example.com (BBBBBBBBBB)\""
private let developerIDLine = "  3) FEDCBA9876543210FEDCBA9876543210FEDCBA98 \"Developer ID Application: Someone (CCCCCCCCCC)\""

private func fixtureLines() throws -> [String] {
    let url = try #require(Bundle.module.url(
        forResource: "find-certificate-wwdr",
        withExtension: "txt",
        subdirectory: "Fixtures"
    ))
    return try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
}

private let identity = SafariSigningIdentity(
    sha1: developmentSHA1,
    name: "Apple Development: dev@example.com (AAAAAAAAAA)"
)

@Test func parsesOnlyAppleDevelopmentIdentities() {
    let lines = [developmentLine, developerIDLine, "     2 valid identities found"]
    #expect(SafariSigning.identities(fromFindIdentityOutput: lines) == [identity])
}

@Test func deduplicatesIdentitiesListedInBothSections() {
    let lines = [
        "Policy: Code Signing", "  Matching identities", developmentLine, "     1 identities found", "",
        "  Valid identities only", developmentLine, "     1 valid identities found",
    ]
    #expect(SafariSigning.identities(fromFindIdentityOutput: lines) == [identity])
}

@Test func statusIsReadyWithValidIdentity() {
    let status = SafariSigning.status(valid: [identity], all: [identity], hasAppleIntermediate: true)
    #expect(status == .ready([identity]))
}

@Test func statusNeedsIntermediateWhenIdentityExistsButG3IsMissing() {
    let status = SafariSigning.status(valid: [], all: [identity], hasAppleIntermediate: false)
    #expect(status == .needsAppleIntermediate)
}

@Test func statusIsUnusableWhenG3PresentButIdentityInvalid() {
    let status = SafariSigning.status(valid: [], all: [identity], hasAppleIntermediate: true)
    #expect(status == .unusable)
}

@Test func statusIsMissingWithoutIdentities() {
    let status = SafariSigning.status(valid: [], all: [], hasAppleIntermediate: true)
    #expect(status == .missing)
}

@Test func multipleIdentitiesAreAllOffered() {
    let all = SafariSigning.identities(fromFindIdentityOutput: [developmentLine, otherDevelopmentLine])
    #expect(SafariSigning.status(valid: all, all: all, hasAppleIntermediate: true) == .ready(all))
    #expect(all.map(\.sha1) == [developmentSHA1, otherDevelopmentSHA1])
}

@Test func detectsG3InFindCertificateOutput() throws {
    let lines = try fixtureLines()
    #expect(SafariSigning.containsAppleIntermediate(findCertificateOutput: lines))
    let withoutG3 = lines.filter { !$0.contains(SafariSigning.appleWWDRG3SHA1) }
    #expect(!SafariSigning.containsAppleIntermediate(findCertificateOutput: withoutG3))
}

@Test func readsExpirationFromPEM() throws {
    let expiry = SafariSigning.expirationDate(
        sha1: SafariSigning.appleWWDRG3SHA1,
        findCertificateOutput: try fixtureLines()
    )
    #expect(expiry == ISO8601DateFormatter().date(from: "2030-02-20T00:00:00Z"))
    #expect(SafariSigning.expirationDate(sha1: developmentSHA1, findCertificateOutput: try fixtureLines()) == nil)
}

@Test func rejectsNonAppleIntermediateBytes() throws {
    let bundled = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SafariExtension/AppleWWDRCAG3.cer")
    #expect(!SafariSigning.isGenuineAppleIntermediate(Data("x".utf8)))
    #expect(SafariSigning.isGenuineAppleIntermediate(try Data(contentsOf: bundled)))
}

@Test func detectCombinesTheThreeSecurityQueries() async {
    let runner = FakeProcessRunner(replays: [
        .init(stdoutLines: ["  Valid identities only", "     0 valid identities found"]),
        .init(stdoutLines: ["  Matching identities", developmentLine, "     1 identities found"]),
        .init(stdoutLines: ["SHA-1 hash: FF6797793A3CD798DC5B2ABEF56F73EDC9F83A64"]),
    ])

    #expect(await SafariSigning.detect(runner: runner) == .needsAppleIntermediate)
    #expect(runner.recordedArguments.allArguments == [
        ["find-identity", "-v", "-p", "codesigning"],
        ["find-identity", "-p", "codesigning"],
        ["find-certificate", "-a", "-Z", "-c", "Apple Worldwide Developer Relations Certification Authority"],
    ])
    #expect(runner.recordedArguments.allExecutableURLs.allSatisfy { $0.path == "/usr/bin/security" })
}

@Test func importRefusesBytesThatAreNotApplesIntermediate() async throws {
    let fake = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).cer")
    try Data("not apple".utf8).write(to: fake)
    defer { try? FileManager.default.removeItem(at: fake) }
    let runner = FakeProcessRunner()

    await #expect(throws: SafariSigningError.notAppleIntermediate) {
        try await SafariSigning.importAppleIntermediate(at: fake, runner: runner)
    }
    #expect(runner.recordedArguments.allArguments.isEmpty)
}

@Test func parsesInvalidIdentityLinesWithReasonSuffix() async {
    let expiredLine = developmentLine + " (CSSMERR_TP_CERT_EXPIRED)"
    #expect(SafariSigning.identities(fromFindIdentityOutput: [expiredLine]) == [identity])

    let runner = FakeProcessRunner(replays: [
        .init(stdoutLines: ["     0 valid identities found"]),
        .init(stdoutLines: [expiredLine]),
        .init(stdoutLines: ["SHA-1 hash: \(SafariSigning.appleWWDRG3SHA1)"]),
    ])
    #expect(await SafariSigning.detect(runner: runner) == .unusable)
}
