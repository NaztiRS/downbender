import SwiftUI

struct URLBar: View {
    @Binding var text: String
    var onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "link").foregroundStyle(Theme.accent)
                    TextField("Paste a link…", text: $text)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit(onSubmit)
                    if !text.isEmpty {
                        Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.tertiary)
                            .accessibilityLabel("Clear link")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)

                Button(action: onSubmit) {
                    Label("Download", systemImage: "arrow.down")
                }
                .buttonStyle(WaveButtonStyle())
                .disabled(text.isEmpty)
            }
            .padding(12)
        }
        // Paste-without-clicking: the field owns the keyboard from the first frame.
        .onAppear { focused = true }
    }
}
