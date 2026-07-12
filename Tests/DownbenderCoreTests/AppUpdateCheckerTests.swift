import Testing
import Foundation
@testable import DownbenderCore

@Suite struct AppUpdateCheckerTests {
    @Test func isNewerComparesSemverIgnoringVPrefix() {
        #expect(AppUpdateChecker.isNewer(latestTag: "v1.1.0", than: "1.0.0"))
        #expect(AppUpdateChecker.isNewer(latestTag: "2.0.0", than: "1.9.9"))
        #expect(!AppUpdateChecker.isNewer(latestTag: "v1.0.0", than: "1.0.0"))
        #expect(!AppUpdateChecker.isNewer(latestTag: "v1.0.0", than: "1.2.0"))
        #expect(AppUpdateChecker.isNewer(latestTag: "v1.0.10", than: "1.0.9"))
    }

    @MainActor @Test func checkPublishesAvailableVersionWhenNewer() async {
        let checker = AppUpdateChecker(installedVersion: "1.0.0", fetchLatest: { "v1.2.0" })
        await checker.check()
        #expect(checker.availableVersion == "1.2.0")
    }

    @MainActor @Test func checkStaysSilentWhenUpToDateOrOffline() async {
        let upToDate = AppUpdateChecker(installedVersion: "1.0.0", fetchLatest: { "v1.0.0" })
        await upToDate.check()
        #expect(upToDate.availableVersion == nil)

        struct Offline: Error {}
        let offline = AppUpdateChecker(installedVersion: "1.0.0", fetchLatest: { throw Offline() })
        await offline.check()
        #expect(offline.availableVersion == nil)
    }
}
