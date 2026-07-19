import SwiftUI
import DownbenderCore

@main
struct DownbenderApp: App {
    @State private var model: AppModel?
    @State private var pendingExternalURLs: [URL] = []

    init() {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("Downbender") {
            Group {
                if let model {
                    RootView(model: model)
                } else {
                    Text("Embedded binaries not found.").padding()
                }
            }
            .onAppear { prepareModel() }
            .onOpenURL(perform: receiveExternalURL)
            .tint(Theme.accent)
            // Dark mode only, by design decision.
            .preferredColorScheme(.dark)
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
        if model == nil { model = Self.makeModel() }
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
        guard let binaries = BundledBinaries.locate(appSupportDirectory: support) else { return nil }
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let tmp = fm.temporaryDirectory.appendingPathComponent("Downbender")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        ChromeIntegrationInstaller.refreshInstalledIntegration()
        return AppModel(
            binaries: binaries, destination: downloads, tmpDirectory: tmp,
            appSupportDirectory: support,
            cookiesBrowser: UserDefaults.standard.string(forKey: AppModel.cookiesBrowserKey),
            notifier: DownloadNotifier()
        )
    }
}
