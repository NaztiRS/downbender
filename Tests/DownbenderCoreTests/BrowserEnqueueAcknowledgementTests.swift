import Foundation
import Testing
@testable import DownbenderCore

@Test func enqueueAcknowledgementWaitsForAndConsumesTheAppSignal() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("browser-ack-\(UUID().uuidString)", isDirectory: true)
    let acknowledgementID = UUID()
    defer { try? fileManager.removeItem(at: root) }
    try BrowserEnqueueAcknowledgement.prepare(
        acknowledgementID,
        appSupportDirectory: root,
        fileManager: fileManager
    )

    DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
        try? BrowserEnqueueAcknowledgement.signal(
            acknowledgementID,
            appSupportDirectory: root
        )
    }

    #expect(BrowserEnqueueAcknowledgement.waitForSignal(
        acknowledgementID,
        appSupportDirectory: root,
        timeout: 0.5,
        pollingInterval: 0.005,
        fileManager: fileManager
    ))
    #expect(!fileManager.fileExists(
        atPath: BrowserEnqueueAcknowledgement.fileURL(
            for: acknowledgementID,
            appSupportDirectory: root
        ).path
    ))
}

@Test func enqueueAcknowledgementTimesOutWithoutAnAppSignal() throws {
    let fileManager = FileManager.default
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("browser-ack-\(UUID().uuidString)", isDirectory: true)
    let acknowledgementID = UUID()
    defer { try? fileManager.removeItem(at: root) }
    try BrowserEnqueueAcknowledgement.prepare(
        acknowledgementID,
        appSupportDirectory: root,
        fileManager: fileManager
    )

    #expect(!BrowserEnqueueAcknowledgement.waitForSignal(
        acknowledgementID,
        appSupportDirectory: root,
        timeout: 0.01,
        pollingInterval: 0.002,
        fileManager: fileManager
    ))
    #expect(!fileManager.fileExists(
        atPath: BrowserEnqueueAcknowledgement.fileURL(
            for: acknowledgementID,
            appSupportDirectory: root
        ).path
    ))
}

@Test func appCannotSignalAnUnregisteredAcknowledgement() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("browser-ack-\(UUID().uuidString)", isDirectory: true)

    #expect(throws: CocoaError.self) {
        try BrowserEnqueueAcknowledgement.signal(
            UUID(),
            appSupportDirectory: root
        )
    }
}
