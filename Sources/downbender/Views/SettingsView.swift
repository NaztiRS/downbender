import SwiftUI
import DownbenderCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var updater: UnifiedUpdater?
    @State private var chromeIntegration: ChromeIntegrationState?
    @State private var installingBrowser: ChromiumBrowser?
    @State private var fileNameTemplateDraft = ""

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

                LabeledContent {
                    HStack(spacing: 8) {
                        Text(model.destination.lastPathComponent).lineLimit(1)
                        Button("Change…") { pickDownloadFolder() }
                    }
                } label: {
                    Label("Download folder", systemImage: "folder")
                }

                Picker(selection: $model.defaultQuality) {
                    Text("Ask every time").tag(DownloadFormat?.none)
                    Text("1080p").tag(DownloadFormat?.some(.video(height: 1080)))
                    Text("720p").tag(DownloadFormat?.some(.video(height: 720)))
                    Text("480p").tag(DownloadFormat?.some(.video(height: 480)))
                    Text("360p").tag(DownloadFormat?.some(.video(height: 360)))
                    Text("Extract MP3").tag(DownloadFormat?.some(.audioMP3))
                } label: {
                    Label("Default quality", systemImage: "slider.horizontal.3")
                }

                Toggle(isOn: $model.oneClickDownload) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Download immediately")
                        Text("Skip the quality panel for videos — uses the default quality (closest available).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(model.defaultQuality == nil)

                VStack(alignment: .leading, spacing: 6) {
                    Label("File name template", systemImage: "textformat")
                    TextField("%(title)s.%(ext)s", text: $fileNameTemplateDraft)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { applyFileNameTemplate() }

                    Group {
                        if let error = FileNameTemplate.validationMessage(for: fileNameTemplateDraft) {
                            Text(error).foregroundStyle(.red)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Supported fields include title, id, uploader, channel, and upload_date.")
                                Text("Media only; direct files keep their server name. Example (no quotes): %(upload_date)s - %(title)s.%(ext)s")
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)

                    HStack {
                        Spacer()
                        Button("Reset") { resetFileNameTemplate() }
                            .disabled(model.fileNameTemplate == FileNameTemplate.defaultValue
                                && fileNameTemplateDraft == FileNameTemplate.defaultValue)
                        Button("Apply") { applyFileNameTemplate() }
                            .disabled(!canApplyFileNameTemplate)
                    }
                }
                .accessibilityElement(children: .contain)
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

            Section("Browser extension") {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Downbender browser extension")
                        Text("Send videos from Chrome, Brave, Edge, or Chromium")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(Theme.accent)
                }

                if let message = chromeIntegration?.errorMessage {
                    Label("Extension unavailable", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let browser = installingBrowser ?? ChromeIntegrationInstaller.installedBrowsers().first {
                        Button("Try again") { beginBrowserInstallation(in: browser) }
                            .buttonStyle(WaveButtonStyle())
                    }
                } else if chromeIntegration?.isAvailable == true {
                    let browsers = ChromeIntegrationInstaller.installedBrowsers()
                    if browsers.isEmpty {
                        Label("Install a supported Chromium browser first", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    } else if let browser = browsers.first, browsers.count == 1 {
                        Button("Install for \(browser.displayName)") {
                            beginBrowserInstallation(in: browser)
                        }
                        .buttonStyle(WaveButtonStyle())
                    } else {
                        Menu("Install Browser Extension") {
                            ForEach(browsers, id: \.self) { browser in
                                Button(browser.displayName) {
                                    beginBrowserInstallation(in: browser)
                                }
                            }
                        }
                    }

                    if let integration = chromeIntegration, integration.isInstalling,
                       let shortcut = integration.temporaryShortcut {
                        Text(
                            "In \(installingBrowser?.displayName ?? "your browser"), " +
                                "choose Load unpacked and select “Downbender Extension Installer”."
                        )
                        .font(.caption).foregroundStyle(.secondary)

                        HStack {
                            Button("Show installer") {
                                NSWorkspace.shared.activateFileViewerSelecting([shortcut])
                            }
                            Button("Cancel") {
                                chromeIntegration = ChromeIntegrationInstaller.cancelInstallation()
                                installingBrowser = nil
                            }
                        }
                    }
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
            if fileNameTemplateDraft.isEmpty {
                fileNameTemplateDraft = model.fileNameTemplate
            }
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

    private func pickDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.destination = url }
    }

    private var canApplyFileNameTemplate: Bool {
        guard let normalized = FileNameTemplate.normalized(fileNameTemplateDraft) else { return false }
        return normalized != model.fileNameTemplate
    }

    private func applyFileNameTemplate() {
        guard model.setFileNameTemplate(fileNameTemplateDraft) else { return }
        fileNameTemplateDraft = model.fileNameTemplate
    }

    private func resetFileNameTemplate() {
        model.resetFileNameTemplate()
        fileNameTemplateDraft = model.fileNameTemplate
    }

    private func beginBrowserInstallation(in browser: ChromiumBrowser) {
        installingBrowser = browser
        let state = ChromeIntegrationInstaller.beginInstallation(for: browser)
        chromeIntegration = state
        guard let shortcut = state.temporaryShortcut else { return }
        NSWorkspace.shared.activateFileViewerSelecting([shortcut])
        openExtensionsPage(in: browser)
    }

    private func openExtensionsPage(in browser: ChromiumBrowser) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", browser.applicationBundleIdentifier, browser.extensionsPage]
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

            case .workingOnEngine(let fraction):
                UpdateProgressView(title: "Updating download engine", fraction: fraction)

            case .workingOnApp(let fraction):
                UpdateProgressView(title: "Downloading Downbender", fraction: fraction)

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

private struct UpdateProgressView: View {
    let title: String
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                if let fraction {
                    Text("\(Int(min(max(fraction, 0), 1) * 100))%")
                        .contentTransition(.numericText())
                } else {
                    Text("Preparing…")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            WaveProgress(fraction: fraction, updatesFrequently: true, height: 11)
        }
        .padding(.vertical, 6)
        .animation(.easeOut(duration: 0.3), value: fraction)
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
