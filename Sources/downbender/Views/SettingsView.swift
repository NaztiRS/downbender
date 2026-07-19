import SwiftUI
import DownbenderCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var updater: UnifiedUpdater?
    @State private var chromeIntegration: ChromeIntegrationState?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 0) {
                            Text("Down").fontWeight(.light).foregroundStyle(.secondary)
                            Text("bender").fontWeight(.bold).foregroundStyle(Theme.accent)
                        }
                        .font(.title2)
                        Text("The last download master · v\(Downbender.version)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }

            Section("General") {
                Stepper(value: $model.maxConcurrent, in: 1...4) {
                    Label("Simultaneous downloads: \(model.maxConcurrent)", systemImage: "square.stack.3d.up.fill")
                }
                .onChange(of: model.maxConcurrent) { _, newValue in model.queue.setMaxConcurrent(newValue) }
            }

            Section("Privacy") {
                Picker(selection: $model.cookiesBrowser) {
                    Text("None").tag(String?.none)
                    Text("Chrome").tag(String?("chrome"))
                    Text("Safari").tag(String?("safari"))
                    Text("Firefox").tag(String?("firefox"))
                    Text("Edge").tag(String?("edge"))
                    Text("Brave").tag(String?("brave"))
                } label: {
                    Label("Browser cookies", systemImage: "lock.shield")
                }
                Text("Only needed for age-restricted or members-only videos. Downbender lets yt-dlp read cookies from the selected browser; macOS may ask for permission once.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Chrome extension") {
                if let message = chromeIntegration?.errorMessage {
                    Label("Extension unavailable", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Try again") { chromeIntegration = ChromeIntegrationInstaller.status() }
                } else if let integration = chromeIntegration, integration.isInstalling,
                          let shortcut = integration.temporaryShortcut {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Temporary installer ready")
                            Text("In Load unpacked, select “Downbender Extension Installer”")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(Theme.accent)
                    }
                    HStack {
                        Button("Open Chrome Extensions") { openChromeExtensions() }
                        Button("Show installer") {
                            NSWorkspace.shared.activateFileViewerSelecting([shortcut])
                        }
                    }
                    Text("Chrome removes this temporary shortcut automatically as soon as the extension loads. Use the fallback below only if it remains in Downloads.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Clean up manually") { finishChromeInstallation() }
                        .buttonStyle(WaveButtonStyle())
                    Button("Cancel installation") {
                        chromeIntegration = ChromeIntegrationInstaller.cancelInstallation()
                    }
                } else if chromeIntegration?.isInstalled == true {
                    Label("Chrome integration installed", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("The extension lives inside Downbender; no installation folder is left in Downloads.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Open Chrome Extensions") { openChromeExtensions() }
                        Button("Reinstall or update") { beginChromeInstallation() }
                    }
                } else if chromeIntegration?.isAvailable == true {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("IDM-style browser button")
                            Text("Appears only on the video currently playing or previewing")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(Theme.accent)
                    }
                    Button("Install Chrome Extension") { beginChromeInstallation() }
                        .buttonStyle(WaveButtonStyle())
                } else {
                    LabeledContent("Checking extension") { ProgressView().controlSize(.small) }
                }
            }

            if let updater {
                UpdatesSection(updater: updater, model: model)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(WashBackground())
        .frame(width: 500, height: 580)
        .task {
            if chromeIntegration == nil {
                chromeIntegration = ChromeIntegrationInstaller.status()
            }
            if updater == nil { updater = model.makeUnifiedUpdater() }
            // Arrived from the "Update" banner: run the check automatically so the user doesn't re-click.
            if model.checkUpdatesOnOpen {
                model.checkUpdatesOnOpen = false
                await updater?.check()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            chromeIntegration = ChromeIntegrationInstaller.status()
        }
    }

    private func beginChromeInstallation() {
        let state = ChromeIntegrationInstaller.beginInstallation()
        chromeIntegration = state
        guard let shortcut = state.temporaryShortcut else { return }
        NSWorkspace.shared.activateFileViewerSelecting([shortcut])
        openChromeExtensions()
    }

    private func finishChromeInstallation() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downbender")
        chromeIntegration = ChromeIntegrationInstaller.finishInstallation(appSupportDirectory: support)
    }

    private func openChromeExtensions() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Google Chrome", "chrome://extensions/"]
        try? process.run()
    }
}

/// One check and one "Update now" cover both the app and the download engine (yt-dlp).
private struct UpdatesSection: View {
    let updater: UnifiedUpdater
    let model: AppModel
    @State private var confirmingRestart = false

    /// Downloads that would be lost when the app relaunches to finish updating.
    private var activeDownloads: Int {
        model.queue.items.filter { item in
            switch item.state {
            case .downloading, .queued, .merging, .paused: true
            default: false
            }
        }.count
    }

    var body: some View {
        Section {
            switch updater.phase {
            case .idle:
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Downbender & download engine")
                        Text("One check covers the app and its engine.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "shippingbox")
                }
                Button("Check for updates") { Task { await updater.check() } }

            case .checking:
                LabeledContent {
                    ProgressView().controlSize(.small)
                } label: {
                    Label("Checking…", systemImage: "arrow.triangle.2.circlepath")
                }

            case .upToDate(let app, let engine):
                Label("You're up to date (v\(app) · engine \(engine))", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Button("Check again") { Task { await updater.check() } }

            case .available(let appVersion, let engineInstalled, let engineLatest):
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Update available")
                        Text(detail(appVersion: appVersion, engineInstalled: engineInstalled, engineLatest: engineLatest))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
                }
                Button("Update now") { Task { await updater.update() } }
                    .buttonStyle(WaveButtonStyle())

            case .workingOnEngine(let fraction), .workingOnApp(let fraction):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Updating…")
                        Spacer()
                        if let fraction {
                            Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    WaveProgress(fraction: fraction)
                }
                .padding(.vertical, 2)

            case .readyToRestart:
                Label("Update installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Restart Downbender") {
                    if activeDownloads > 0 { confirmingRestart = true } else { relaunchApp() }
                }
                .buttonStyle(WaveButtonStyle())
                .confirmationDialog("Restart to finish updating?", isPresented: $confirmingRestart, titleVisibility: .visible) {
                    Button("Restart (cancels \(activeDownloads) download\(activeDownloads == 1 ? "" : "s"))", role: .destructive) { relaunchApp() }
                    Button("Not now", role: .cancel) {}
                } message: {
                    Text("\(activeDownloads) download\(activeDownloads == 1 ? " is" : "s are") still in progress and will be cancelled when Downbender restarts.")
                }

            case .failed(let message):
                Label("Update failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Retry") { Task { await updater.check() } }
            }
        } header: {
            Text("Updates")
        }
    }

    private func detail(appVersion: String?, engineInstalled: String?, engineLatest: String?) -> String {
        var parts: [String] = []
        if let appVersion { parts.append("Downbender v\(Downbender.version) → v\(appVersion)") }
        if let engineInstalled, let engineLatest { parts.append("engine \(engineInstalled) → \(engineLatest)") }
        return parts.joined(separator: " · ")
    }
}

/// Relaunches the (already swapped) bundle: a detached shell re-opens it right after this process exits.
@MainActor private func relaunchApp() {
    let path = Bundle.main.bundlePath
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "sleep 0.7; /usr/bin/open \"\(path)\""]
    try? process.run()
    NSApp.terminate(nil)
}
