import SwiftUI
import DownbenderCore

/// Error panel with selectable text: native macOS alerts don't allow selecting the message.
struct ErrorDetailSheet: View {
    let title: String
    let message: String
    var onClose: () -> Void
    var engineRecoveryTitle: String?
    var onEngineRecovery: (() -> Void)?
    var diagnosticsReport: String?
    var onRetryWithDiagnostics: (() -> Void)?

    @Environment(\.openSettings) private var openSettings
    @State private var copied = false

    init(
        title: String,
        message: String,
        onClose: @escaping () -> Void,
        engineRecoveryTitle: String? = nil,
        onEngineRecovery: (() -> Void)? = nil,
        diagnosticsReport: String? = nil,
        onRetryWithDiagnostics: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.onClose = onClose
        self.engineRecoveryTitle = engineRecoveryTitle
        self.onEngineRecovery = onEngineRecovery
        self.diagnosticsReport = diagnosticsReport
        self.onRetryWithDiagnostics = onRetryWithDiagnostics
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if let hint {
                Label(hint.message, systemImage: "lightbulb.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Suggestion: \(hint.message)")
            }
            if diagnosticsReport != nil {
                Label(
                    "Full URLs, local paths, and cookie details are removed. Nothing is sent automatically.",
                    systemImage: "hand.raised.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    "Privacy: Full URLs, local paths, and cookie details are removed. Nothing is sent automatically."
                )
            }
            ScrollView {
                Text(diagnosticsReport ?? message)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 260)
            if hint?.suggestedAction == .openSettings || engineRecoveryTitle != nil {
                HStack {
                    if hint?.suggestedAction == .openSettings {
                        Button {
                            openSettings()
                        } label: {
                            Label("Open Settings…", systemImage: "gearshape")
                        }
                        .accessibilityHint("Choose a browser under Browser cookies, then try the download again")
                    }

                    if let engineRecoveryTitle, let onEngineRecovery {
                        Button {
                            onEngineRecovery()
                        } label: {
                            Label(engineRecoveryTitle, systemImage: "sparkles")
                        }
                        .accessibilityHint("Retries this item with a different yt-dlp engine")
                    }
                    Spacer()
                }
            }
            HStack {
                Button(action: copyError) {
                    Label(copyButtonTitle, systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityLabel(copyAccessibilityLabel)
                .accessibilityValue(copied ? "Copied" : "")
                .accessibilityHint(copyAccessibilityHint)

                if let onRetryWithDiagnostics {
                    Button {
                        onRetryWithDiagnostics()
                    } label: {
                        Label("Retry with diagnostics", systemImage: "doc.text.magnifyingglass")
                    }
                    .accessibilityHint(
                        "Retries this item with detailed logging. Nothing is sent automatically."
                    )
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
        YtdlpErrorHint.hint(for: diagnosticsReport ?? message)
    }

    private var copyButtonTitle: String {
        if diagnosticsReport != nil {
            return copied ? "Diagnostics copied" : "Copy diagnostics"
        }
        return copied ? "Copied" : "Copy"
    }

    private var copyAccessibilityLabel: String {
        if diagnosticsReport != nil {
            return "Copy diagnostics"
        }
        return "Copy error"
    }

    private var copyAccessibilityHint: String {
        if diagnosticsReport != nil {
            return "Copies a privacy-safe diagnostics report to the clipboard"
        }
        return "Copies the full error message to the clipboard"
    }

    private func copyError() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsReport ?? message, forType: .string)
        copied = true
    }
}
