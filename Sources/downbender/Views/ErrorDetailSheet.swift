import SwiftUI
import DownbenderCore

/// Error panel with selectable text: native macOS alerts don't allow selecting the message.
struct ErrorDetailSheet: View {
    let title: String
    let message: String
    var onClose: () -> Void

    @Environment(\.openSettings) private var openSettings
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if let hint {
                Label(hint.message, systemImage: "lightbulb.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Suggestion: \(hint.message)")
            }
            ScrollView {
                Text(message)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 260)
            HStack {
                Button(action: copyError) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityLabel(copied ? "Error copied" : "Copy error")
                .accessibilityHint("Copies the full error message to the clipboard")

                if hint?.suggestedAction == .openSettings {
                    Button {
                        openSettings()
                    } label: {
                        Label("Open Settings…", systemImage: "gearshape")
                    }
                    .accessibilityHint("Choose a browser under Browser cookies, then try the download again")
                }

                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 480)
        .background(Theme.wash)
    }

    private var hint: YtdlpErrorHint.Hint? {
        YtdlpErrorHint.hint(for: message)
    }

    private func copyError() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
        copied = true
    }
}
