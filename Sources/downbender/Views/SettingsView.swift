import SwiftUI
import DownbenderCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var chromeIntegration: ChromeIntegrationState?
    @State private var browserInventory = BrowserInventory(installed: [])
    @State private var selectedBrowser: BrowserKind?
    @State private var installingBrowser: BrowserKind?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    ZStack {
                        Rectangle()
                            .fill(Theme.raised)
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .scaledToFit()
                            .padding(7)
                    }
                    .frame(width: 54, height: 54)
                    .overlay(Rectangle().strokeBorder(Theme.borderStrong))

                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("DOWNBENDER")
                                .font(.system(size: 19, weight: .semibold))
                                .tracking(-0.3)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("PREFERENCES")
                                .commandMetadata()
                        }

                        HStack(spacing: 8) {
                            Circle()
                                .fill(Theme.success)
                                .frame(width: 6, height: 6)
                            Text("DOWNLOAD CONTROL")
                                .commandMetadata()
                            Spacer()
                            Text("V\(Downbender.version)")
                                .commandMetadata()
                        }
                    }
                }
                .commandPanel(padding: 14)
            }

            Section {
                VStack(alignment: .leading, spacing: 0) {
                    Stepper(value: $model.maxConcurrent, in: 1...4) {
                        Label("Simultaneous downloads: \(model.maxConcurrent)", systemImage: "square.stack.3d.up.fill")
                    }
                    .onChange(of: model.maxConcurrent) { _, newValue in model.queue.setMaxConcurrent(newValue) }
                    .commandRow()

                    CommandRule()

                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(model.destination.lastPathComponent)
                                .lineLimit(1)
                                .foregroundStyle(Theme.muted)
                            Button("Change…") { pickDownloadFolder() }
                                .buttonStyle(CommandButtonStyle(.secondary))
                        }
                    } label: {
                        Label("Download folder", systemImage: "folder")
                    }
                    .commandRow()

                    CommandRule()

                    VStack(alignment: .leading, spacing: 6) {
                        Picker(selection: $model.defaultQuality) {
                            Text("Ask every time").tag(DownloadFormat?.none)
                            Divider()
                            Text(DownloadFormat.maximumVideo.preferenceLabel)
                                .tag(DownloadFormat?.some(.maximumVideo))
                            Text(DownloadFormat.video(height: 2160).preferenceLabel)
                                .tag(DownloadFormat?.some(.video(height: 2160)))
                            Text(DownloadFormat.video(height: 1440).preferenceLabel)
                                .tag(DownloadFormat?.some(.video(height: 1440)))
                            Text(DownloadFormat.video(height: 1080).preferenceLabel)
                                .tag(DownloadFormat?.some(.video(height: 1080)))
                            Text(DownloadFormat.video(height: 720).preferenceLabel)
                                .tag(DownloadFormat?.some(.video(height: 720)))
                            Text(DownloadFormat.video(height: 480).preferenceLabel)
                                .tag(DownloadFormat?.some(.video(height: 480)))
                            Text(DownloadFormat.video(height: 360).preferenceLabel)
                                .tag(DownloadFormat?.some(.video(height: 360)))
                            Divider()
                            ForEach(DownloadFormat.audioFormats) { format in
                                Text(format.preferenceLabel)
                                    .tag(DownloadFormat?.some(format))
                            }
                        } label: {
                            Label("Default quality", systemImage: "slider.horizontal.3")
                        }

                        Text(defaultQualityDetail)
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                            .accessibilityLabel("Default quality details")
                            .accessibilityValue(defaultQualityDetail)
                    }
                    .commandRow()

                    CommandRule()

                    Toggle(isOn: $model.oneClickDownload) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Download immediately")
                            Text("Skip the quality panel for videos — uses the default quality.")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(model.defaultQuality == nil)
                    .commandRow()

                    CommandRule()

                    FileNameSettings(model: model)
                        .commandRow()
                }
                .commandPanel()
            } header: {
                CommandSectionHeader(index: "01", title: "General")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Browser cookies")
                            Text("Use a signed-in browser for restricted videos.")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                    } icon: {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(Theme.accent)
                    }

                    CommandRule(inset: 0)

                    Picker("Browser", selection: $model.cookiesBrowser) {
                        Text("None").tag(BrowserKind?.none)
                        ForEach(browserInventory.cookieBrowsers) { browser in
                            Text(browser.displayName)
                                .tag(BrowserKind?.some(browser))
                        }
                    }
                    .pickerStyle(.menu)

                    Text("Downbender lets yt-dlp read cookies from the selected browser; macOS may ask for permission once.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                .commandPanel(padding: 14)
            } header: {
                CommandSectionHeader(index: "02", title: "Privacy")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Downbender browser extension")
                            Text("Send videos from Google Chrome, Brave, Microsoft Edge, or Chromium")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                    } icon: {
                        Image(systemName: "puzzlepiece.extension.fill")
                            .foregroundStyle(Theme.accent)
                    }

                    CommandRule(inset: 0)

                    let browsers = browserInventory.chromiumBrowsers.map(\.browserKind)
                    if browsers.isEmpty {
                        Label("Install a supported Chromium browser first", systemImage: "info.circle")
                            .foregroundStyle(Theme.muted)
                    } else {
                        Picker("Browser", selection: browserSelection(for: browsers)) {
                            ForEach(browsers, id: \.self) { browser in
                                Text(browser.displayName)
                                    .tag(browser)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(chromeIntegration?.isInstalling == true)

                        if let message = chromeIntegration?.errorMessage {
                            Label("Extension unavailable", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.warning)
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                                .textSelection(.enabled)
                            if let browser = resolvedBrowser(from: browsers) {
                                Button("Try again") { beginBrowserInstallation(in: browser) }
                                    .buttonStyle(CommandButtonStyle(.primary))
                            }
                        } else if chromeIntegration?.isAvailable == true {
                            if let integration = chromeIntegration, integration.isInstalling,
                               let shortcut = integration.temporaryShortcut {
                                Text(
                                    "In \(installingBrowser?.displayName ?? resolvedBrowser(from: browsers)?.displayName ?? "your browser"), " +
                                        "choose Load unpacked and select “Downbender Extension Installer”."
                                )
                                .font(.caption)
                                .foregroundStyle(Theme.muted)

                                HStack {
                                    Button("Show installer") {
                                        NSWorkspace.shared.activateFileViewerSelecting([shortcut])
                                    }
                                    .buttonStyle(CommandButtonStyle(.secondary))
                                    Button("Cancel") {
                                        chromeIntegration = ChromeIntegrationInstaller.cancelInstallation()
                                        installingBrowser = nil
                                    }
                                    .buttonStyle(CommandButtonStyle(.danger))
                                }
                            } else if let browser = resolvedBrowser(from: browsers) {
                                Button("Install extension") {
                                    beginBrowserInstallation(in: browser)
                                }
                                .buttonStyle(CommandButtonStyle(.primary))
                            }
                        } else {
                            LabeledContent("Checking extension") {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(Theme.accent)
                            }
                        }
                    }
                }
                .commandPanel(padding: 14)
            } header: {
                CommandSectionHeader(index: "03", title: "Browser extension")
            }

            DownloadEngineSection(controller: model.engineController)
            UpdatesSection(updater: model.updater, model: model)
        }
        .formStyle(CommandFormStyle())
        .scrollContentBackground(.hidden)
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.accent)
        .background(Theme.canvas)
        .preferredColorScheme(.dark)
        .frame(width: 500, height: 580)
        .task {
            refreshBrowserState()
            await model.engineController.refreshVersions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshBrowserState()
        }
    }

    private func pickDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.destination = url }
    }

    private var defaultQualityDetail: String {
        guard let format = model.defaultQuality else {
            return "Choose a quality separately for each video."
        }
        switch format {
        case .maximumVideo:
            return "Downloads the highest resolution available · MP4 through 1080p, MKV above · files can be much larger."
        case .video(let height):
            return "Uses the closest available resolution at or below \(height)p · MP4 through 1080p, MKV above."
        case .audioMP3:
            return "Extracts audio as MP3 · works with nearly every player."
        case .audioM4A:
            return "Extracts audio as M4A · a good fit for Apple apps and devices."
        case .audioOpus:
            return "Extracts audio as Opus · efficient modern audio; some older apps may not support it."
        }
    }

    private func beginBrowserInstallation(in browser: BrowserKind) {
        guard let chromiumBrowser = browser.chromiumBrowser else { return }
        selectedBrowser = browser
        installingBrowser = browser
        let state = ChromeIntegrationInstaller.beginInstallation(for: chromiumBrowser)
        chromeIntegration = state
        guard let shortcut = state.temporaryShortcut else { return }
        NSWorkspace.shared.activateFileViewerSelecting([shortcut])
        openExtensionsPage(in: chromiumBrowser)
    }

    private func openExtensionsPage(in browser: ChromiumBrowser) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", browser.applicationBundleIdentifier, browser.extensionsPage]
        try? process.run()
    }

    private func refreshBrowserState() {
        let inventory = BrowserApplicationDetector.inventory()
        browserInventory = inventory
        chromeIntegration = ChromeIntegrationInstaller.status()

        if let cookiesBrowser = model.cookiesBrowser, !inventory.installed.contains(cookiesBrowser) {
            model.cookiesBrowser = nil
        }

        let extensionBrowsers = inventory.chromiumBrowsers.map(\.browserKind)
        if let selectedBrowser, extensionBrowsers.contains(selectedBrowser) { return }
        selectedBrowser = extensionBrowsers.first
    }

    private func resolvedBrowser(from browsers: [BrowserKind]) -> BrowserKind? {
        if let selectedBrowser, browsers.contains(selectedBrowser) {
            return selectedBrowser
        }
        return browsers.first
    }

    private func browserSelection(for browsers: [BrowserKind]) -> Binding<BrowserKind> {
        Binding(
            get: { resolvedBrowser(from: browsers) ?? .chrome },
            set: { selectedBrowser = $0 }
        )
    }
}

private enum FileNameStyle: Hashable {
    case preset(FileNameTemplate.Preset)
    case custom
}

private extension FileNameTemplate.Preset {
    var settingsTitle: String {
        switch self {
        case .title: "Title"
        case .channelAndTitle: "Channel — Title"
        case .uploadDateAndTitle: "Date — Title"
        case .titleAndIdentifier: "Title [Identifier]"
        }
    }
}

private struct FileNameSettings: View {
    @Bindable var model: AppModel
    @State private var style: FileNameStyle = .preset(.title)
    @State private var customDraft = FileNameTemplate.defaultValue
    @State private var didInitialize = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FILE OUTPUT")
                        .commandMetadata()
                    Text("Name format")
                        .fontWeight(.medium)
                }
                Spacer()
                Picker("Name format", selection: styleBinding) {
                    ForEach(FileNameTemplate.Preset.allCases) { preset in
                        Text(preset.settingsTitle)
                            .tag(FileNameStyle.preset(preset))
                    }
                    Divider()
                    Text("Custom…")
                        .tag(FileNameStyle.custom)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 160)
            }

            preview

            if style == .custom {
                customEditor
            }
        }
        .task { initialize() }
    }

    private var styleBinding: Binding<FileNameStyle> {
        Binding(
            get: { style },
            set: { select($0) }
        )
    }

    private var selectedTemplate: String {
        switch style {
        case let .preset(preset): preset.template
        case .custom: customDraft
        }
    }

    private var previewText: String {
        if let example = FileNameTemplate.example(for: selectedTemplate) {
            return example
        }
        if FileNameTemplate.normalized(selectedTemplate) != nil {
            return "Preview unavailable for this advanced format."
        }
        return "Fix the custom format to see an example."
    }

    private var isSaved: Bool {
        guard let normalized = FileNameTemplate.normalized(selectedTemplate) else { return false }
        return normalized == model.fileNameTemplate
    }

    private var statusText: String {
        if style == .custom,
           let preset = FileNameTemplate.Preset.matching(selectedTemplate) {
            return isSaved ? "Using \(preset.settingsTitle)" : "\(preset.settingsTitle) preset"
        }
        return isSaved ? "Saved" : "Not saved"
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text("OUTPUT / EXAMPLE")
                    .commandMetadata()
                Spacer(minLength: 8)
                Label(
                    statusText.uppercased(),
                    systemImage: isSaved ? "checkmark.circle.fill" : "circle.dashed"
                )
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(isSaved ? Theme.success : Theme.warning)
            }

            Text(previewText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised)
        .overlay(Rectangle().strokeBorder(Theme.border))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("File name preview")
        .accessibilityValue("\(previewText). \(statusText).")
    }

    private var customEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("TEMPLATE / ADVANCED")
                .commandMetadata()
            TextField("%(title)s.%(ext)s", text: $customDraft)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.canvas)
                .overlay(Rectangle().strokeBorder(
                    customValidationMessage == nil ? Theme.borderStrong : Theme.danger
                ))
                .accessibilityLabel("Custom file name format")
                .accessibilityHint(
                    customValidationMessage.map { "Invalid format: \($0)" }
                        ?? "Fields such as title and channel are replaced when the file is named."
                )
                .onSubmit { saveCustomFormat() }

            if let error = customValidationMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
                    .accessibilityLabel("Invalid custom format: \(error)")
            } else {
                Text("Advanced: fields such as %(title)s and %(channel)s are replaced when the file is named.")
                    .foregroundStyle(Theme.muted)
            }

            HStack {
                Button("Use Title Preset") {
                    select(.preset(.title))
                }
                .buttonStyle(CommandButtonStyle(.secondary))
                Spacer()
                Button("Save Custom Format") {
                    saveCustomFormat()
                }
                .buttonStyle(CommandButtonStyle(.primary))
                .disabled(!canSaveCustomFormat)
            }
        }
        .font(.system(size: 11))
        .padding(.top, 2)
    }

    private var customValidationMessage: String? {
        FileNameTemplate.validationMessage(for: customDraft)
    }

    private var canSaveCustomFormat: Bool {
        guard let normalized = FileNameTemplate.normalized(customDraft) else { return false }
        return normalized != model.fileNameTemplate
    }

    private func initialize() {
        guard !didInitialize else { return }
        let activeTemplate = model.fileNameTemplate
        if let preset = FileNameTemplate.Preset.matching(activeTemplate) {
            style = .preset(preset)
            customDraft = model.lastCustomFileNameTemplate ?? activeTemplate
        } else {
            style = .custom
            customDraft = activeTemplate
        }
        didInitialize = true
    }

    private func select(_ newStyle: FileNameStyle) {
        style = newStyle
        switch newStyle {
        case .preset(.title):
            model.resetFileNameTemplate()
        case let .preset(preset):
            model.setFileNameTemplate(preset.template)
        case .custom:
            break
        }
    }

    private func saveCustomFormat() {
        guard canSaveCustomFormat else { return }
        guard model.setFileNameTemplate(customDraft) else { return }
        customDraft = model.fileNameTemplate
        if let preset = FileNameTemplate.Preset.matching(model.fileNameTemplate) {
            style = .preset(preset)
            customDraft = model.lastCustomFileNameTemplate ?? model.fileNameTemplate
        }
    }
}

private struct DownloadEngineSection: View {
    @Bindable var controller: YtdlpEngineController

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("yt-dlp download engine")
                        Text("Stable stays bundled; nightly is downloaded only when you request it.")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                } icon: {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .foregroundStyle(Theme.accent)
                }

                CommandRule(inset: 0)

                Picker("Active engine", selection: channelBinding) {
                    Text("Stable · bundled").tag(YtdlpEngineChannel.stable)
                    if controller.nightlyInstalled {
                        Text("Nightly · latest fixes").tag(YtdlpEngineChannel.nightly)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(controller.isInstalling)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Using \(controller.selectedChannel.displayName)")
                        .font(.caption.weight(.semibold))
                    Text(versionDetail)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                    Text("Stable always remains available offline. Nightly may fix recent site changes sooner.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }

                switch controller.phase {
                case .idle:
                    Button(controller.nightlyInstalled ? "Update latest fixes" : "Try latest fixes") {
                        Task { try? await controller.installLatestAndSelect() }
                    }
                    .buttonStyle(CommandButtonStyle(.secondary))
                    .accessibilityHint("Downloads, verifies, and selects the latest official yt-dlp nightly")

                case .installing(let fraction):
                    UpdateProgressView(title: "Installing latest fixes", fraction: fraction)

                case .failed(let message):
                    Label("Latest fixes update failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .textSelection(.enabled)
                    HStack {
                        Button("Try again") {
                            Task { try? await controller.installLatestAndSelect() }
                        }
                        .buttonStyle(CommandButtonStyle(.secondary))
                        if controller.selectedChannel != .stable {
                            Button("Use stable") { controller.useStable() }
                                .buttonStyle(CommandButtonStyle(.secondary))
                        }
                    }
                }
            }
            .commandPanel(padding: 14)
        } header: {
            CommandSectionHeader(index: "04", title: "Download engine")
        }
    }

    private var channelBinding: Binding<YtdlpEngineChannel> {
        Binding(
            get: { controller.selectedChannel },
            set: { channel in
                Task { try? await controller.select(channel) }
            }
        )
    }

    private var versionDetail: String {
        let stable = controller.stableVersion ?? "bundled version"
        guard controller.nightlyInstalled else {
            return "Stable \(stable) · Nightly not installed"
        }
        let nightly = controller.nightlyVersion ?? "installed"
        return "Stable \(stable) · Nightly \(nightly)"
    }
}

/// Downbender application updates are independent from the optional nightly engine.
private struct UpdatesSection: View {
    let updater: UnifiedUpdater
    @Bindable var model: AppModel
    @State private var confirmingRestart = false

    /// Downloads that would be interrupted when the app relaunches to finish updating.
    private var activeDownloads: Int {
        TerminationPolicy.interruptedCount(model.queue.items)
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $model.automaticAppUpdatesEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatically update Downbender")
                        Text("Installs new app versions automatically. You choose when to restart.")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                }
                .toggleStyle(.switch)

                CommandRule(inset: 0)

                switch updater.phase {
                case .idle:
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Downbender application")
                            Text("Checks for a newer Downbender release.")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                    } icon: {
                        Image(systemName: "shippingbox")
                            .foregroundStyle(Theme.accent)
                    }
                    Button("Check for updates") {
                        Task { await model.checkForUpdates() }
                    }
                    .buttonStyle(CommandButtonStyle(.secondary))

                case .checking:
                    LabeledContent {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.accent)
                    } label: {
                        Label("Checking…", systemImage: "arrow.triangle.2.circlepath")
                    }

                case .upToDate(let app):
                    Label("Downbender v\(app) is up to date", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.success)
                    Button("Check again") {
                        Task { await model.checkForUpdates() }
                    }
                    .buttonStyle(CommandButtonStyle(.secondary))

                case .available(let appVersion):
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Update available")
                            Text("Downbender v\(Downbender.version) → v\(appVersion)")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(Theme.accent)
                    }
                    Button("Update now") {
                        Task { await updater.update() }
                    }
                    .buttonStyle(CommandButtonStyle(.primary))

                case .workingOnApp(let fraction):
                    UpdateProgressView(title: "Downloading Downbender", fraction: fraction)

                case .readyToRestart:
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Downbender was updated")
                            Text("Restart whenever you're ready.")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                    }
                    Button("Restart Downbender") {
                        if activeDownloads > 0 { confirmingRestart = true } else { relaunchApp() }
                    }
                    .buttonStyle(CommandButtonStyle(.primary))
                    .confirmationDialog(
                        "Restart to finish updating?",
                        isPresented: $confirmingRestart,
                        titleVisibility: .visible
                    ) {
                        Button(
                            "Restart (pauses \(activeDownloads) download\(activeDownloads == 1 ? "" : "s"))",
                            role: .destructive
                        ) {
                            relaunchApp()
                        }
                        Button("Not now", role: .cancel) {}
                    } message: {
                        Text("\(activeDownloads) download\(activeDownloads == 1 ? " is" : "s are") still in progress and will be paused before Downbender restarts.")
                    }

                case .failed(let message):
                    Label("Update failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .textSelection(.enabled)
                    Button("Retry") {
                        Task { await model.checkForUpdates() }
                    }
                    .buttonStyle(CommandButtonStyle(.secondary))
                }
            }
            .commandPanel(padding: 14)
        } header: {
            CommandSectionHeader(index: "05", title: "Downbender updates")
        }
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
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.muted)

            CommandProgressBar(fraction: fraction)
        }
        .padding(.vertical, 6)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

private struct CommandSectionHeader: View {
    let index: String
    let title: String

    var body: some View {
        HStack(spacing: 9) {
            Text(index)
                .foregroundStyle(Theme.accent)
            Text(title.uppercased())
                .foregroundStyle(Theme.muted)
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .tracking(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

private struct CommandRule: View {
    var inset: CGFloat = 14

    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(height: 1)
            .padding(.horizontal, inset)
            .accessibilityHidden(true)
    }
}

private enum CommandButtonEmphasis {
    case primary
    case secondary
    case danger
}

private struct CommandButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let emphasis: CommandButtonEmphasis

    init(_ emphasis: CommandButtonEmphasis) {
        self.emphasis = emphasis
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(foreground)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Rectangle().fill(background))
            .overlay(Rectangle().strokeBorder(stroke))
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.38)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch emphasis {
        case .primary: Theme.canvas
        case .secondary: Theme.textPrimary
        case .danger: Theme.danger
        }
    }

    private var background: Color {
        switch emphasis {
        case .primary: Theme.accent
        case .secondary, .danger: Theme.raised
        }
    }

    private var stroke: Color {
        switch emphasis {
        case .primary: Theme.accent
        case .secondary: Theme.borderStrong
        case .danger: Theme.danger
        }
    }
}

private struct CommandProgressBar: View {
    let fraction: Double?

    var body: some View {
        if let fraction {
            GeometryReader { geometry in
                let progress = min(max(fraction, 0), 1)
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.raised)
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: geometry.size.width * progress)
                }
                .overlay(Rectangle().strokeBorder(Theme.border))
            }
            .frame(height: 7)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(Theme.accent)
        }
    }
}

private extension View {
    func commandMetadata() -> some View {
        font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(0.9)
            .foregroundStyle(Theme.muted)
    }

    func commandRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
    }

    func commandPanel(padding: CGFloat = 0) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Theme.surface)
            .overlay(Rectangle().strokeBorder(Theme.border))
            .listRowBackground(Color.clear)
    }
}

/// Removes the rounded grouped-form plates so the command panels are the only
/// visible cards and keep their deliberately rectangular geometry.
private struct CommandFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                configuration.content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
    }
}

/// Asks the app delegate to save/stop active work, terminate fully, and only then
/// reopen the already-swapped bundle.
@MainActor func relaunchApp() {
    (NSApp.delegate as? DownbenderAppDelegate)?.requestRelaunch()
}
