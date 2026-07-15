import SwiftUI
import DownbenderCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var updater: UnifiedUpdater?

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

            if let updater {
                UpdatesSection(updater: updater, model: model)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(WashBackground())
        .frame(width: 480, height: 470)
        .task {
            if updater == nil { updater = model.makeUnifiedUpdater() }
            // Arrived from the "Update" banner: run the check automatically so the user doesn't re-click.
            if model.checkUpdatesOnOpen {
                model.checkUpdatesOnOpen = false
                await updater?.check()
            }
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
