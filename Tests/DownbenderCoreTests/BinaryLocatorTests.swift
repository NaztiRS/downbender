import Testing
import Foundation
@testable import DownbenderCore

@Test func prefersUpdatedYtdlpWhenPresent() {
    let updated = URL(fileURLWithPath: "/support/yt-dlp_macos")
    let bundled = URL(fileURLWithPath: "/app/yt-dlp_macos")
    let resolved = BinaryLocator.resolveYtdlp(updated: updated, bundled: bundled, fileExists: { $0 == updated })
    #expect(resolved == updated)
}

@Test func fallsBackToBundledWhenNoUpdate() {
    let updated = URL(fileURLWithPath: "/support/yt-dlp_macos")
    let bundled = URL(fileURLWithPath: "/app/yt-dlp_macos")
    let resolved = BinaryLocator.resolveYtdlp(updated: updated, bundled: bundled, fileExists: { _ in false })
    #expect(resolved == bundled)
}
