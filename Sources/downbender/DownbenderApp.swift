import SwiftUI
import DownbenderCore

@main
struct DownbenderApp: App {
    @State private var model: AppModel?

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
            .onAppear { if model == nil { model = Self.makeModel() } }
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

    @MainActor private static func makeModel() -> AppModel? {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Downbender")
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
