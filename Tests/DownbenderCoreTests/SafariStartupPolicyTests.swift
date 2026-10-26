import Foundation
import Testing
@testable import DownbenderCore

private let installedApp = URL(fileURLWithPath: "/Applications/Downbender.app")
private let repoApp = URL(fileURLWithPath: "/Users/someone/Code/downbender/Downbender.app")

private func record(
    version: String = "1.9.0",
    mode: SafariExtensionMode = .quick,
    owner: URL = installedApp,
    expiry: Date? = nil
) -> SafariInstallRecord {
    SafariInstallRecord(templateVersion: version, mode: mode, ownerAppPath: owner.path, certificateExpiry: expiry)
}

private func shouldRefresh(
    _ record: SafariInstallRecord?,
    current: URL = installedApp,
    version: String,
    ownerExists: Bool = true,
    identityAvailable: Bool = true
) -> Bool {
    SafariStartupPolicy.shouldRefresh(
        record: record,
        currentAppURL: current,
        currentTemplateVersion: version,
        ownerExists: ownerExists,
        identityAvailable: identityAvailable
    )
}

@Test func refreshesWhenOwnerRunsNewerTemplate() {
    #expect(shouldRefresh(record(version: "1.9.0"), version: "1.9.1"))
}

@Test func doesNotRefreshSameVersion() {
    #expect(!shouldRefresh(record(version: "1.9.0"), version: "1.9.0"))
    #expect(!shouldRefresh(nil, version: "1.9.0"))
}

@Test func nonOwnerCopyNeverTakesOver() {
    #expect(!shouldRefresh(record(version: "1.9.0", owner: installedApp), current: repoApp, version: "2.0.0"))
}

@Test func adoptsWhenOwnerIsGoneButNeverDowngrades() {
    let gone = record(version: "1.9.0", owner: installedApp)
    #expect(shouldRefresh(gone, current: repoApp, version: "1.9.0", ownerExists: false))
    #expect(shouldRefresh(gone, current: repoApp, version: "1.9.2", ownerExists: false))
    #expect(!shouldRefresh(gone, current: repoApp, version: "1.8.6", ownerExists: false))
}

@Test func ephemeralLocationsAreDetected() {
    #expect(SafariStartupPolicy.isEphemeralLocation(URL(fileURLWithPath: "/Volumes/Downbender/Downbender.app")))
    #expect(SafariStartupPolicy.isEphemeralLocation(
        URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/y/d/Downbender.app")
    ))
    #expect(!SafariStartupPolicy.isEphemeralLocation(installedApp))
}

@Test func ephemeralCopyNeverRefreshes() {
    let dmg = URL(fileURLWithPath: "/Volumes/Downbender/Downbender.app")
    #expect(!shouldRefresh(record(owner: dmg), current: dmg, version: "9.9.9"))
    #expect(!shouldRefresh(record(owner: installedApp), current: dmg, version: "9.9.9", ownerExists: false))
}

@Test func permanentRefreshIsSkippedWithoutIdentity() {
    let permanent = record(version: "1.9.0", mode: .permanent(identitySHA1: "ABC"))
    #expect(!shouldRefresh(permanent, version: "2.0.0", identityAvailable: false))
    #expect(shouldRefresh(permanent, version: "2.0.0", identityAvailable: true))
}

@Test func attentionReportsMissingCertificate() {
    let permanent = record(mode: .permanent(identitySHA1: "ABC"))
    #expect(SafariStartupPolicy.attention(record: permanent, identityAvailable: false, now: Date()) == .certificateMissing)
    #expect(SafariStartupPolicy.attention(record: record(mode: .quick), identityAvailable: false, now: Date()) == nil)
    #expect(SafariStartupPolicy.attention(record: nil, identityAvailable: false, now: Date()) == nil)
}

@Test func attentionWarns30DaysBeforeExpiry() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let soon = now.addingTimeInterval(29 * 86_400)
    let later = now.addingTimeInterval(31 * 86_400)
    let permanent = SafariExtensionMode.permanent(identitySHA1: "ABC")
    #expect(SafariStartupPolicy.attention(
        record: record(mode: permanent, expiry: soon), identityAvailable: true, now: now
    ) == .certificateExpiringSoon(soon))
    #expect(SafariStartupPolicy.attention(
        record: record(mode: permanent, expiry: later), identityAvailable: true, now: now
    ) == nil)
}

@Test func attentionReportsExpired() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let past = now.addingTimeInterval(-60)
    #expect(SafariStartupPolicy.attention(
        record: record(mode: .permanent(identitySHA1: "ABC"), expiry: past), identityAvailable: true, now: now
    ) == .certificateExpired(past))
}

@Test func recordRoundTripsThroughJSON() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/install.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let original = record(mode: .permanent(identitySHA1: "ABC"), expiry: Date(timeIntervalSince1970: 1_900_000_000))

    try original.save(to: url)
    #expect(SafariInstallRecord.load(from: url) == original)
    #expect(SafariInstallRecord.load(from: url.appendingPathExtension("missing")) == nil)
}

@Test func refreshIsNotRetriedForAVersionThatAlreadyFailed() {
    var failed = record(version: "1.9.0")
    failed.failedRefreshVersion = "1.9.1"
    #expect(!shouldRefresh(failed, version: "1.9.1"))
    #expect(shouldRefresh(failed, version: "1.9.2"))
}

@Test func attentionReportsFailedUpdate() {
    var failed = record(mode: .quick)
    failed.failedRefreshVersion = "1.9.1"
    #expect(SafariStartupPolicy.attention(record: failed, identityAvailable: true, now: Date()) == .updateFailed)
}

private let oldIdentity = SafariSigningIdentity(sha1: String(repeating: "A", count: 40), name: "Apple Development: dev@example.com (AAAAAAAAAA)")
private let newIdentity = SafariSigningIdentity(sha1: String(repeating: "B", count: 40), name: "Apple Development: dev@example.com (AAAAAAAAAA)")
private let renewalNow = Date(timeIntervalSince1970: 1_800_000_000)

private func renewal(
    recordedExpiry: Date?,
    ready: [SafariSigningIdentity],
    expiries: [String: Date],
    mode: SafariExtensionMode = .permanent(identitySHA1: oldIdentity.sha1),
    current: URL = installedApp,
    ownerExists: Bool = true
) -> SafariSigningIdentity? {
    SafariStartupPolicy.renewalIdentity(
        record: record(mode: mode, owner: installedApp, expiry: recordedExpiry),
        currentAppURL: current,
        ownerExists: ownerExists,
        ready: ready,
        expiries: expiries,
        now: renewalNow
    )
}

@Test func renewalPicksANewerCertificateWhenRecordedOneIsGone() {
    let next = renewal(
        recordedExpiry: renewalNow.addingTimeInterval(-60),
        ready: [newIdentity],
        expiries: [newIdentity.sha1: renewalNow.addingTimeInterval(365 * 86_400)]
    )
    #expect(next == newIdentity)
}

@Test func renewalPicksANewerCertificateWhenRecordedOneExpiresSoon() {
    let next = renewal(
        recordedExpiry: renewalNow.addingTimeInterval(10 * 86_400),
        ready: [oldIdentity, newIdentity],
        expiries: [
            oldIdentity.sha1: renewalNow.addingTimeInterval(10 * 86_400),
            newIdentity.sha1: renewalNow.addingTimeInterval(365 * 86_400),
        ]
    )
    #expect(next == newIdentity)
}

@Test func noRenewalWhileRecordedCertificateIsHealthy() {
    let next = renewal(
        recordedExpiry: renewalNow.addingTimeInterval(200 * 86_400),
        ready: [oldIdentity, newIdentity],
        expiries: [newIdentity.sha1: renewalNow.addingTimeInterval(365 * 86_400)]
    )
    #expect(next == nil)
}

@Test func noRenewalWithoutALaterCertificate() {
    let soon = renewalNow.addingTimeInterval(10 * 86_400)
    #expect(renewal(recordedExpiry: soon, ready: [oldIdentity], expiries: [oldIdentity.sha1: soon]) == nil)
    #expect(renewal(
        recordedExpiry: soon,
        ready: [oldIdentity, newIdentity],
        expiries: [newIdentity.sha1: renewalNow.addingTimeInterval(5 * 86_400)]
    ) == nil)
}

@Test func noRenewalForQuickModeOrAnotherCopy() {
    let gone = renewalNow.addingTimeInterval(-60)
    let fresh = [newIdentity.sha1: renewalNow.addingTimeInterval(365 * 86_400)]
    #expect(renewal(recordedExpiry: gone, ready: [newIdentity], expiries: fresh, mode: .quick) == nil)
    #expect(renewal(recordedExpiry: gone, ready: [newIdentity], expiries: fresh, current: repoApp) == nil)
    #expect(renewal(recordedExpiry: gone, ready: [newIdentity], expiries: fresh, current: repoApp, ownerExists: false)
        == newIdentity)
}

@Test func attentionReportsExpiredEvenWhenIdentityIsGone() {
    let past = renewalNow.addingTimeInterval(-60)
    #expect(SafariStartupPolicy.attention(
        record: record(mode: .permanent(identitySHA1: "ABC"), expiry: past), identityAvailable: false, now: renewalNow
    ) == .certificateExpired(past))
}
