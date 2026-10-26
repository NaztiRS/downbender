import Foundation
import Testing
@testable import DownbenderCore

@MainActor
private final class OpenedLinks {
    var urls: [URL] = []

    func send(_ message: Any) async -> [String: Any] {
        await SafariRequestRouter.response(to: message) { self.urls.append($0) }
    }
}

private let encodedSource = "https://example.com/video?q=a%26b&title=café#part-two"

@MainActor @Test func safariDeliversOnceWithoutClaimingQueueConfirmation() async {
    let opened = OpenedLinks()
    let response = await opened.send(["command": "enqueue", "url": "https://example.com/video"])

    #expect(response["ok"] as? Bool == true)
    #expect(response["confirmed"] as? Bool == false)
    #expect(opened.urls.count == 1)
}

@MainActor @Test func deepLinkPreservesEscapesUnicodeAndFragment() async {
    let opened = OpenedLinks()
    _ = await opened.send(["command": "enqueue", "url": encodedSource])

    #expect(opened.urls.count == 1)
    #expect(opened.urls.first.flatMap(BrowserBridge.webURL(from:))?.absoluteString
        == URL(string: encodedSource)?.absoluteString)
}

@MainActor @Test func safariNeverRequestsAFileAcknowledgement() async throws {
    let opened = OpenedLinks()
    _ = await opened.send(["command": "enqueue", "url": encodedSource])

    let deepLink = try #require(opened.urls.first)
    #expect(BrowserBridge.deepLinkRequest(from: deepLink)?.acknowledgementID == nil)
}

@MainActor @Test func safariOverlayNeverTurnsAVideoIntoAPlaylist() async {
    let opened = OpenedLinks()
    let response = await opened.send([
        "command": "enqueue",
        "url": "https://www.youtube.com/watch?v=video123&list=RDvideo123",
        "source": "active-video-overlay",
    ])

    #expect(response["ok"] as? Bool == true)
    #expect(opened.urls.first.flatMap(BrowserBridge.webURL(from:))?.absoluteString
        == "https://www.youtube.com/watch?v=video123")
}

@MainActor @Test func safariRejectsMalformedOrUnsafeMessagesWithoutOpeningTheApp() async {
    let opened = OpenedLinks()
    let invalid: [Any] = [
        NSNull(), "enqueue", ["command": "delete", "url": encodedSource],
        ["command": "enqueue"], ["command": "enqueue", "url": 42],
        ["command": "enqueue", "url": "file:///etc/passwd"],
        ["command": "enqueue", "url": "javascript:alert(1)"],
        ["command": "enqueue", "url": "downbender://add?url=https://example.com"],
        ["command": "enqueue", "url": "https://"],
        ["command": "enqueue", "url": "https://example.com/" + String(repeating: "x", count: 32_768)],
        ["command": "enqueue", "url": "https://www.youtube.com/feed/subscriptions", "source": "active-video-overlay"],
    ]

    for message in invalid {
        let response = await opened.send(message)
        #expect(response["ok"] as? Bool == false, "\(message)")
        #expect(response["message"] as? String == "This is not a downloadable web address.", "\(message)")
    }
    #expect(opened.urls.isEmpty)
}

@MainActor @Test func safariReportsAnActionableErrorWhenDownbenderCannotOpen() async {
    struct NotInstalled: Error {}
    let response = await SafariRequestRouter.response(to: ["command": "enqueue", "url": encodedSource]) { _ in
        throw NotInstalled()
    }

    #expect(response["ok"] as? Bool == false)
    #expect(response["message"] as? String == "Could not open Downbender. Make sure it is installed in Applications.")
}

private let installed = URL(fileURLWithPath: "/Applications/Downbender.app")
private let repoBuild = URL(fileURLWithPath: "/Users/someone/Code/downbender/Downbender.app")

@Test func resolvePrefersRunningApp() {
    let target = SafariAppTarget.resolve(
        runningApps: [repoBuild],
        recordedPath: installed.path,
        fileExists: { _ in true },
        registeredApp: installed
    )
    #expect(target == repoBuild)
}

@Test func resolveUsesRecordedPathWhenNothingRuns() {
    let target = SafariAppTarget.resolve(
        runningApps: [],
        recordedPath: repoBuild.path,
        fileExists: { _ in true },
        registeredApp: installed
    )
    #expect(target == repoBuild)
}

@Test func resolveFallsBackToRegisteredAppWhenRecordedPathIsGone() {
    let target = SafariAppTarget.resolve(
        runningApps: [],
        recordedPath: repoBuild.path,
        fileExists: { $0 != repoBuild.path },
        registeredApp: installed
    )
    #expect(target == installed)
}

@Test func resolveReturnsNilWhenNoDownbenderExists() {
    let target = SafariAppTarget.resolve(
        runningApps: [],
        recordedPath: nil,
        fileExists: { _ in false },
        registeredApp: nil
    )
    #expect(target == nil)
}
