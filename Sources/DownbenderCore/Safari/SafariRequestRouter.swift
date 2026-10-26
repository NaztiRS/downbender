// Also compiled standalone into the Safari extension together with BrowserBridge.swift
// (scripts/build-safari-extension.sh): import only Foundation and use nothing from
// DownbenderCore except BrowserBridge and BrowserExtensionRequest.
import Foundation

/// Turns a Safari native message into Downbender's `downbender://add` deep link. The extension is
/// sandboxed and cannot read the app's file acknowledgement, so success means "delivered", never
/// "added to the queue".
@MainActor
enum SafariRequestRouter {
    static func response(
        to message: Any,
        openURL: (URL) async throws -> Void
    ) async -> [String: Any] {
        guard let dictionary = message as? [String: Any],
              JSONSerialization.isValidJSONObject(dictionary),
              let data = try? JSONSerialization.data(withJSONObject: dictionary),
              let request = try? JSONDecoder().decode(BrowserExtensionRequest.self, from: data),
              request.command == "enqueue",
              let webURL = BrowserBridge.downloadURL(for: request),
              let deepLink = BrowserBridge.deepLink(for: webURL)
        else {
            return ["ok": false, "message": "This is not a downloadable web address."]
        }

        do {
            try await openURL(deepLink)
            return ["ok": true, "confirmed": false]
        } catch {
            return ["ok": false, "message": "Could not open Downbender. Make sure it is installed in Applications."]
        }
    }
}

/// Chooses which Downbender receives a Safari link. A running copy wins so a second instance never
/// opens over the same queue; otherwise the copy that installed the extension, then Launch Services.
enum SafariAppTarget {
    static func resolve(
        runningApps: [URL],
        recordedPath: String?,
        fileExists: (String) -> Bool,
        registeredApp: URL?
    ) -> URL? {
        if let running = runningApps.first { return running }
        if let recordedPath, fileExists(recordedPath) {
            return URL(fileURLWithPath: recordedPath)
        }
        return registeredApp
    }
}
