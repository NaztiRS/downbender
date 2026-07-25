import Foundation

/// File-based handshake between the short-lived native-messaging helper and the GUI app.
/// A UUID-scoped file survives the small launch race without opening a listening socket.
public enum BrowserEnqueueAcknowledgement {
    private static let directoryName = "BrowserAcknowledgements"
    private static let pendingState = Data("pending".utf8)

    public static func fileURL(for id: UUID, appSupportDirectory: URL) -> URL {
        appSupportDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("\(id.uuidString.lowercased()).enqueued")
    }

    private static func pendingURL(for id: UUID, appSupportDirectory: URL) -> URL {
        appSupportDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("\(id.uuidString.lowercased()).pending")
    }

    public static func clear(
        _ id: UUID,
        appSupportDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        for file in [
            pendingURL(for: id, appSupportDirectory: appSupportDirectory),
            fileURL(for: id, appSupportDirectory: appSupportDirectory),
        ] where fileManager.fileExists(atPath: file.path) {
            try fileManager.removeItem(at: file)
        }
    }

    /// Registers a one-time request before the app is opened. The app refuses to create a signal
    /// without this marker, so arbitrary custom URLs cannot litter Application Support with files.
    public static func prepare(
        _ id: UUID,
        appSupportDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        try clear(id, appSupportDirectory: appSupportDirectory, fileManager: fileManager)
        let file = pendingURL(for: id, appSupportDirectory: appSupportDirectory)
        try fileManager.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try pendingState.write(to: file, options: .atomic)
    }

    public static func signal(
        _ id: UUID,
        appSupportDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let pending = pendingURL(for: id, appSupportDirectory: appSupportDirectory)
        guard try Data(contentsOf: pending) == pendingState else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Both paths share a directory, so this rename is the one-way pending → enqueued
        // transition. If the host timed out and removed pending, no late orphan is created.
        try fileManager.moveItem(
            at: pending,
            to: fileURL(for: id, appSupportDirectory: appSupportDirectory)
        )
    }

    /// Waits for the app to signal that it created a queue card, consuming the signal on success.
    public static func waitForSignal(
        _ id: UUID,
        appSupportDirectory: URL,
        timeout: TimeInterval,
        pollingInterval: TimeInterval = 0.025,
        fileManager: FileManager = .default
    ) -> Bool {
        let file = fileURL(for: id, appSupportDirectory: appSupportDirectory)
        let deadline = Date().addingTimeInterval(max(0, timeout))
        defer { try? clear(id, appSupportDirectory: appSupportDirectory, fileManager: fileManager) }
        while true {
            if fileManager.fileExists(atPath: file.path) { return true }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            Thread.sleep(forTimeInterval: min(max(0.001, pollingInterval), remaining))
        }
    }
}
