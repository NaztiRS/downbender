import SwiftUI

struct URLBar: View {
    @Binding var text: String
    var onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ADD RESOURCE")
                Spacer()
                Text("PASTE URL · PRESS RETURN")
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .tracking(0.9)
            .foregroundStyle(Theme.muted)

            HStack(spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: "link")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    TextField("Paste a link…", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .focused($focused)
                        .onSubmit(onSubmit)
                    if !text.isEmpty {
                        Button { text = "" } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.muted)
                        .accessibilityLabel("Clear link")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Theme.surface, in: .rect(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(focused ? Theme.accent : Theme.border, lineWidth: 1)
                }

                Button(action: onSubmit) {
                    Label("Execute", systemImage: "arrow.down")
                }
                .buttonStyle(WaveButtonStyle())
                .disabled(text.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Theme.canvas)
        // Paste-without-clicking: the field owns the keyboard from the first frame.
        .onAppear { focused = true }
    }
}
