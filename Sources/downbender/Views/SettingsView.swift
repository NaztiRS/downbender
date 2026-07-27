import SwiftUI
import DownbenderCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var updater: UnifiedUpdater?
    @State private var chromeIntegration: ChromeIntegrationState?
    @State private var installingBrowser: ChromiumBrowser?

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
                            Text(DownloadFormat.audioMP3.preferenceLabel)
                                .tag(DownloadFormat?.some(.audioMP3))
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
                VStack(alignment: .leading, spacing: 0) {
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
                    .commandRow()

                    CommandRule()

                    Text("Only needed for age-restricted or members-only videos. Downbender lets yt-dlp read cookies from the selected browser; macOS may ask for permission once.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .commandRow()
                }
                .commandPanel()
            } header: {
                CommandSectionHeader(index: "02", title: "Privacy")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Downbender browser extension")
                            Text("Send videos from Chrome, Brave, Edge, or Chromium")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                    } icon: {
                        Image(systemName: "puzzlepiece.extension.fill")
                            .foregroundStyle(Theme.accent)
                    }

                    CommandRule(inset: 0)

                    if let message = chromeIntegration?.errorMessage {
                        Label("Extension unavailable", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                            .textSelection(.enabled)
                        if let browser = installingBrowser ?? ChromeIntegrationInstaller.installedBrowsers().first {
                            Button("Try again") { beginBrowserInstallation(in: browser) }
                                .buttonStyle(CommandButtonStyle(.primary))
                        }
                    } else {
                        if chromeIntegration?.isAvailable == true {
                            let browsers = ChromeIntegrationInstaller.installedBrowsers()
                            if browsers.isEmpty {
                                Label("Install a supported Chromium browser first", systemImage: "info.circle")
                                    .foregroundStyle(Theme.muted)
                            } else if let browser = browsers.first, browsers.count == 1 {
                                Button("Install for \(browser.displayName)") {
                                    beginBrowserInstallation(in: browser)
                                }
                                .buttonStyle(CommandButtonStyle(.primary))
                            } else {
                                Menu("Install Browser Extension") {
                                    ForEach(browsers, id: \.self) { browser in
                                        Button(browser.displayName) {
                                            beginBrowserInstallation(in: browser)
                                        }
                                    }
                                }
                                .menuStyle(.button)
                                .buttonStyle(CommandButtonStyle(.primary))
                            }

                            if let integration = chromeIntegration, integration.isInstalling,
                               let shortcut = integration.temporaryShortcut {
                                Text(
                                    "In \(installingBrowser?.displayName ?? "your browser"), " +
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

            if let updater {
                UpdatesSection(updater: updater, model: model)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.accent)
        .background(Theme.canvas)
        .preferredColorScheme(.dark)
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
            return "Extracts the audio as an MP3 file."
        }
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
            VStack(alignment: .leading, spacing: 12) {
                switch updater.phase {
                case .idle:
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Downbender & download engine")
                            Text("One check covers the app and its engine.")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                    } icon: {
                        Image(systemName: "shippingbox")
                            .foregroundStyle(Theme.accent)
                    }
                    Button("Check for updates") {
                        Task { await updater.check() }
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

                case .upToDate(let app, let engine):
                    Label("You're up to date (v\(app) · engine \(engine))", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.success)
                    Button("Check again") {
                        Task { await updater.check() }
                    }
                    .buttonStyle(CommandButtonStyle(.secondary))

                case .available(let appVersion, let engineInstalled, let engineLatest):
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Update available")
                            Text(detail(
                                appVersion: appVersion,
                                engineInstalled: engineInstalled,
                                engineLatest: engineLatest
                            ))
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

                case .workingOnEngine(let fraction):
                    UpdateProgressView(title: "Updating download engine", fraction: fraction)

                case .workingOnApp(let fraction):
                    UpdateProgressView(title: "Downloading Downbender", fraction: fraction)

                case .readyToRestart:
                    Label("Update installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
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
                            "Restart (cancels \(activeDownloads) download\(activeDownloads == 1 ? "" : "s"))",
                            role: .destructive
                        ) {
                            relaunchApp()
                        }
                        Button("Not now", role: .cancel) {}
                    } message: {
                        Text("\(activeDownloads) download\(activeDownloads == 1 ? " is" : "s are") still in progress and will be cancelled when Downbender restarts.")
                    }

                case .failed(let message):
                    Label("Update failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .textSelection(.enabled)
                    Button("Retry") {
                        Task { await updater.check() }
                    }
                    .buttonStyle(CommandButtonStyle(.secondary))
                }
            }
            .commandPanel(padding: 14)
        } header: {
            CommandSectionHeader(index: "04", title: "Updates")
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

/// Relaunches the (already swapped) bundle: a detached shell re-opens it right after this process exits.
@MainActor private func relaunchApp() {
    let path = Bundle.main.bundlePath
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "sleep 0.7; /usr/bin/open \"\(path)\""]
    try? process.run()
    NSApp.terminate(nil)
}
