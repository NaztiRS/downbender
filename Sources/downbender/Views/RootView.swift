import SwiftUI
import CoreTransferable
import DownbenderCore

struct RootView: View {
    @State var model: AppModel
    @State private var urlText = ""
    @State private var isDropTargeted = false
    @State private var windowIsRenderable = false
    @State private var lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            set: { if !$0 { model.dismissPlaylistChoice() } }
        )) {
            if let url = model.pendingPlaylistChoice {
                PlaylistScopePrompt(
                    url: url,
                    onVideo: { model.chooseVideoOnly() },
                    onPlaylist: { model.chooseWholePlaylist() },
                    onDismiss: { model.dismissPlaylistChoice() }
                )
            }
        }
        .task { await model.appUpdate.check() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.clipboard.check(pasteboardString: NSPasteboard.general.string(forType: .string))
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .background(AtmosphereBackground())
        .background {
            WindowRenderStateReader(isRenderable: $windowIsRenderable)
                .frame(width: 0, height: 0)
        }
        .frame(minWidth: 560, minHeight: 420)
        .dropDestination(for: DroppedWebContent.self) { items, _ in
            enqueueDropped(items.map(\.text))
        } isTargeted: {
            isDropTargeted = $0
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.surface.opacity(0.92))
                    .overlay {
                        Label("Drop links to download", systemImage: "link.badge.plus")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    }
                    .padding(8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
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
        .environment(\.continuousVisualEffectsAllowed, continuousVisualEffectsAllowed)
    }

    private var continuousVisualEffectsAllowed: Bool {
        scenePhase == .active
            && windowIsRenderable
            && !lowPowerModeEnabled
            && !reduceMotion
    }

    /// Never blocks: cards appear instantly and probes run in the background. Pasting a
    /// list of links enqueues every one of them.
    private func submit() {
        let urls = URLBatch.split(urlText)
        guard !urls.isEmpty else { return }
        urlText = ""
        for url in urls { model.addURL(url) }
    }

    /// Browser drags usually arrive as URL, while selections and some apps expose plain
    /// text. Both representations land here and may contain more than one link.
    private func enqueueDropped(_ items: [String]) -> Bool {
        let urls = URLBatch.droppedWebURLs(items)
        guard !urls.isEmpty else { return false }
        for url in urls { model.addURL(url) }
        return true
    }
}

/// One drop payload with URL and plain-text import representations. URL comes first so
/// browser link drags keep their canonical URL; the text fallback also supports batches.
private struct DroppedWebContent: Transferable {
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { (url: URL) in
            DroppedWebContent(text: url.absoluteString)
        }
        ProxyRepresentation { (text: String) in
            DroppedWebContent(text: text)
        }
    }
}
