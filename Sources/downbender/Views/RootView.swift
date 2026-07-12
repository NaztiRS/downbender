import SwiftUI
import DownbenderCore

struct RootView: View {
    @State var model: AppModel
    @State private var urlText = ""

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
                    SettingsLink {
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
            QueueList(model: model)
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
