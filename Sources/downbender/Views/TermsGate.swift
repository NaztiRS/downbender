import SwiftUI

/// First-run acceptance gate. Shown once (per terms version); blocks use until accepted.
struct TermsGate: View {
    var onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Before you start").font(.title2.weight(.bold))
            Text("""
            Downbender downloads whatever link you give it. You are responsible for what you \
            download and how you use it, including copyright and any files that turn out to be \
            harmful. macOS checks downloaded apps and installers when you open them, but nothing \
            is guaranteed. Downbender is provided as-is, with no warranty.
            """)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("I understand", action: onAccept)
                    .buttonStyle(WaveButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.wash)
        .interactiveDismissDisabled()
    }
}
