import AppKit
import SwiftUI
import DownbenderCore

@MainActor
private final class DownbenderAppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        let active = TerminationPolicy.interruptedCount(model.queue.items)
        guard active > 0 else {
            model.saveQueueNow()
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = active == 1 ? "1 download in progress" : "\(active) downloads in progress"
        alert.informativeText = "Downloads will be paused — you can resume them next time you open Downbender."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task { @MainActor in
            // Pauses everything, waits (≤3 s) for child processes to be reaped, saves the queue.
            await model.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_: Notification) {
        ChromeIntegrationInstaller.cleanUpTemporaryInstaller()
    }
}

@main
struct DownbenderApp: App {
    @NSApplicationDelegateAdaptor(DownbenderAppDelegate.self) private var appDelegate
    @State private var model: AppModel?
    @State private var pendingExternalURLs: [URL] = []

    init() {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        Window("Downbender", id: "main") {
            Group {
                if let model {
                    RootView(model: model)
                } else {
                    Text("Embedded binaries not found.").padding()
                }
            }
            .onAppear { prepareModel() }
            .onOpenURL(perform: receiveExternalURL)
            .handlesExternalEvents(preferring: ["add"], allowing: ["add"])
            .tint(Theme.accent)
            // Dark mode only, by design decision.
            .preferredColorScheme(.dark)
        }
        .commands {
            CommandGroup(after: .pasteboard) {
                Button("Paste and Download") {
                    // The delegate holds the model (wired in prepareModel); commands closures
                    // don't observe @State reliably, the delegate reference is always current.
                    guard let model = appDelegate.model,
                          let text = NSPasteboard.general.string(forType: .string) else { return }
                    for url in URLBatch.split(text) { model.addURL(url) }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }
        }
        Settings {
            if let model {
                SettingsView(model: model)
                    .tint(Theme.accent)
                    .preferredColorScheme(.dark)
            }
        }
    }

    @MainActor private func prepareModel() {
        if model == nil {
            model = Self.makeModel()
            if let model {
                appDelegate.model = model
                // Restore BEFORE sweeping, so rehydrated paused items protect their .part files.
                model.restoreQueue()
                model.sweepTemporary()
            }
        }
        guard let model else { return }
        for url in pendingExternalURLs { model.addURL(url.absoluteString) }
        pendingExternalURLs.removeAll()
    }

    @MainActor private func receiveExternalURL(_ deepLink: URL) {
        guard let webURL = BrowserBridge.webURL(from: deepLink) else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let model {
            model.addURL(webURL.absoluteString)
        } else {
            pendingExternalURLs.append(webURL)
        }
    }

    @MainActor private static func makeModel() -> AppModel? {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Downbender")
        ChromeIntegrationInstaller.prepareIntegration()
        guard let binaries = BundledBinaries.locate(appSupportDirectory: support) else { return nil }
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let tmp = fm.temporaryDirectory.appendingPathComponent("Downbender")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        return AppModel(
            binaries: binaries, destination: downloads, tmpDirectory: tmp,
            appSupportDirectory: support,
            cookiesBrowser: UserDefaults.standard.string(forKey: AppModel.cookiesBrowserKey),
            notifier: DownloadNotifier()
        )
    }
}
