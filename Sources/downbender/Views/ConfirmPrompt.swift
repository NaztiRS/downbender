import SwiftUI

struct ConfirmPrompt: View {
    let url: String
    var onAccept: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Video link detected", systemImage: "link.badge.plus")
                .font(.headline)
                .foregroundStyle(Theme.accent)
            Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                Spacer()
                Button("Ignore", action: onDismiss)
                Button("Download", action: onAccept)
                    .buttonStyle(WaveButtonStyle())
            }
        }
        .padding(18).frame(width: 360)
        .background(Theme.wash)
    }
}
