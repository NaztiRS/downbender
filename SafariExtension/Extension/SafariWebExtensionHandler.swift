import AppKit
import SafariServices

@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let request = PendingRequest(context: context)
        Task { @MainActor in
            let context = request.context
            let item = context.inputItems.first as? NSExtensionItem
            let message = item?.userInfo?[SFExtensionMessageKey] ?? NSNull()
            let result = await SafariRequestRouter.response(to: message) { url in
                let target = SafariAppTarget.resolve(
                    runningApps: NSRunningApplication
                        .runningApplications(withBundleIdentifier: BrowserBridge.appBundleIdentifier)
                        .compactMap(\.bundleURL),
                    recordedPath: Bundle.main.object(forInfoDictionaryKey: "DownbenderAppPath") as? String,
                    fileExists: { FileManager.default.fileExists(atPath: $0) },
                    registeredApp: NSWorkspace.shared.urlForApplication(withBundleIdentifier: BrowserBridge.appBundleIdentifier)
                )
                guard let appURL = target else { throw CocoaError(.fileNoSuchFile) }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
            }
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: result]
            context.completeRequest(returningItems: [response])
        }
    }

    // NSExtensionContext supports asynchronous completion but has no Sendable annotation.
    // Transfer it to exactly one task; the callback never accesses it after this handoff.
    private struct PendingRequest: @unchecked Sendable {
        let context: NSExtensionContext
    }
}
