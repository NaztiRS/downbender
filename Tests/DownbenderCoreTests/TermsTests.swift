import Testing
import Foundation
@testable import DownbenderCore

@MainActor
@Test func termsDefaultToNotAcceptedThenPersist() {
    let suite = "terms-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(
        binaries: BundledBinaries(ytdlp: URL(fileURLWithPath: "/y"), ffmpegDirectory: URL(fileURLWithPath: "/f"), deno: nil),
        destination: URL(fileURLWithPath: "/tmp"), tmpDirectory: URL(fileURLWithPath: "/tmp"),
        appSupportDirectory: URL(fileURLWithPath: "/tmp"), runner: FakeProcessRunner(), defaults: defaults)

    #expect(model.termsAccepted == false)
    #expect(model.showTerms == true)
    model.termsAccepted = true
    #expect(model.termsAccepted == true)
    #expect(defaults.string(forKey: AppModel.termsAcceptedKey) == AppModel.currentTermsVersion)
}

@MainActor
@Test func termsStayAcceptedAcrossModelInit() {
    let suite = "terms-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(AppModel.currentTermsVersion, forKey: AppModel.termsAcceptedKey)
    let model = AppModel(
        binaries: BundledBinaries(ytdlp: URL(fileURLWithPath: "/y"), ffmpegDirectory: URL(fileURLWithPath: "/f"), deno: nil),
        destination: URL(fileURLWithPath: "/tmp"), tmpDirectory: URL(fileURLWithPath: "/tmp"),
        appSupportDirectory: URL(fileURLWithPath: "/tmp"), runner: FakeProcessRunner(), defaults: defaults)
    #expect(model.termsAccepted == true)
    #expect(model.showTerms == false)
}
