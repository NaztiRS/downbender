import SwiftUI
import DownbenderCore

struct RootView: View {
    @State var model: AppModel
    @State private var urlText = ""
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            URLBar(text: $urlText, onSubmit: submit)
                .sheet(isPresented: Binding(
                    get: { model.clipboard.detectedURL != nil },
                    set: { if !$0 { model.clipboard.detectedURL = nil } }
                )) {
                    if let url = model.clipboard.detectedURL {
                        ConfirmPrompt(
                            url: url,
                            onAccept: { let u = url; model.clipboard.detectedURL = nil; urlText = u; submit() },
                            onDismiss: { model.clipboard.detectedURL = nil }
                        )
                    }
                }
            if let version = model.appUpdate.availableVersion, !model.appUpdate.dismissed {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.glow)
                    Text("Downbender v\(version) is available")
                        .font(.callout)
                    Button {
                        // Auto-run the update check on arrival so the user doesn't have to press it in Settings.
                        model.checkUpdatesOnOpen = true
                        openSettings()
                    } label: {
                        Text("Update").font(.callout.weight(.semibold)).foregroundStyle(Theme.glow)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button {
                        model.appUpdate.dismissed = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.surface)
            }
            Divider()
                // Anchored here (not the VStack, which owns the playlist-choice sheet): one sheet per view.
                .sheet(isPresented: $model.showTerms) {
                    TermsGate(onAccept: { model.termsAccepted = true; model.showTerms = false })
                }
            QueueList(model: model)
                // Anchored here, not on URLBar: one sheet per view (the clipboard prompt owns that one).
                .sheet(isPresented: Binding(
                    get: { model.playlistAnalysis != nil },
                    set: { if !$0 { model.dismissPlaylistAnalysis() } }
                )) {
                    if let analysis = model.playlistAnalysis {
                        PlaylistPanel(
                            analysis: analysis,
                            destination: $model.destination,
                            onConfirm: { format, includeSubtitles in
                                model.acceptPlaylist(analysis.playlist, format: format, includeSubtitles: includeSubtitles)
                            },
                            onCancel: { model.dismissPlaylistAnalysis() }
                        )
                    }
                }
        }
        // Anchored to the outer VStack: URLBar owns the clipboard sheet and QueueList the playlist panel.
        .sheet(isPresented: Binding(
            get: { model.pendingPlaylistChoice != nil },
            set: { if !$0 { model.pendingPlaylistChoice = nil } }
        )) {
            if let url = model.pendingPlaylistChoice {
                PlaylistScopePrompt(
                    url: url,
                    onVideo: { model.chooseVideoOnly() },
                    onPlaylist: { model.chooseWholePlaylist() },
                    onDismiss: { model.pendingPlaylistChoice = nil }
                )
            }
        }
        .task { await model.appUpdate.check() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.clipboard.check(pasteboardString: NSPasteboard.general.string(forType: .string))
        }
        .background(AtmosphereBackground())
        .frame(minWidth: 560, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        // Title bar in the app's own deep blue instead of the system gray.
        .toolbarBackground(Color.adaptive(light: 0xEDF5FD, dark: 0x0B1E38), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
    }

    /// Never blocks: the card appears instantly and the probe runs in the background.
    private func submit() {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        urlText = ""
        model.addURL(url)
    }
}
