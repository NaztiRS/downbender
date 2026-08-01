import SwiftUI
import CoreTransferable
import DownbenderCore

struct RootView: View {
    @State var model: AppModel
    @State private var urlText = ""
    @State private var isDropTargeted = false
    @State private var confirmingUpdateRestart = false
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
            if model.updater.phase == .readyToRestart {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Downbender was updated")
                        Text("Restart when you're ready.")
                            .foregroundStyle(Theme.muted)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    Button {
                        if activeDownloads > 0 {
                            confirmingUpdateRestart = true
                        } else {
                            relaunchApp()
                        }
                    } label: {
                        Text("RESTART")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.surface)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.border).frame(height: 1)
                }
            } else if !model.automaticAppUpdatesEnabled,
                      case let .available(version) = model.updater.phase,
                      model.dismissedAppUpdateVersion != version {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.square.fill")
                        .foregroundStyle(Theme.accent)
                    Text("Downbender v\(version) is available")
                        .font(.system(size: 11, design: .monospaced))
                    Button {
                        openSettings()
                    } label: {
                        Text("UPDATE")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button {
                        model.dismissAppUpdate(version: version)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.surface)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.border).frame(height: 1)
                }
            }
            Divider()
                .overlay(Theme.border)
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
                            onConfirm: { entries, format, includeSubtitles in
                                model.acceptPlaylist(
                                    analysis.playlist,
                                    selectedEntries: entries,
                                    format: format,
                                    includeSubtitles: includeSubtitles
                                )
                            },
                            onCancel: { model.dismissPlaylistAnalysis() }
                        )
                        .id(ObjectIdentifier(analysis))
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
        .task { model.startUpdateChecks() }
        .confirmationDialog(
            "Restart to finish updating?",
            isPresented: $confirmingUpdateRestart,
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
            Text(
                "\(activeDownloads) download\(activeDownloads == 1 ? " is" : "s are") " +
                    "still in progress and will be paused before Downbender restarts."
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.clipboard.check(pasteboardString: NSPasteboard.general.string(forType: .string))
        }
        .background(AtmosphereBackground())
        .frame(minWidth: 560, minHeight: 420)
        .dropDestination(for: DroppedWebContent.self) { items, _ in
            enqueueDropped(items.map(\.text))
        } isTargeted: {
            isDropTargeted = $0
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.raised.opacity(0.98))
                    .overlay {
                        Label("Drop links to download", systemImage: "link.badge.plus")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.accent)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
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
        .toolbarBackground(Theme.canvas, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .tint(Theme.accent)
    }

    /// Downloads that would be interrupted if the user accepts the restart banner.
    private var activeDownloads: Int {
        TerminationPolicy.interruptedCount(model.queue.items)
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
