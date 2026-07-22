import SwiftUI

/// A pasted watch link that also carries a playlist (`v=` + `list=`): ask which one the user meant.
struct PlaylistScopePrompt: View {
    let url: String
    var onVideo: () -> Void
    var onPlaylist: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("This link is part of a playlist", systemImage: "music.note.list")
                .font(.headline)
                .foregroundStyle(Theme.accent)
            Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                Spacer()
                Button("Cancel", action: onDismiss)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button("Only this video", action: onVideo)
                Button("Whole playlist", action: onPlaylist)
                    .buttonStyle(WaveButtonStyle())
            }
        }
        .padding(18).frame(width: 440)
        .background(Theme.wash)
    }
}
