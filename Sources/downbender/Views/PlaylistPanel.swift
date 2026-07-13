import SwiftUI
import DownbenderCore

/// One choice for the whole playlist: entries are enqueued directly (no per-video probe),
/// so the quality list is fixed and each video resolves to its closest available quality.
struct PlaylistPanel: View {
    let playlist: PlaylistProbe
    @Binding var destination: URL
    var onConfirm: (DownloadFormat, Bool) -> Void
    var onCancel: () -> Void

    @State private var selection: DownloadFormat = .video(height: 1080)
    @State private var includeSubtitles = false

    private static let choices: [DownloadFormat] = [
        .video(height: 1080), .video(height: 720), .video(height: 480), .video(height: 360), .audioMP3,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("DOWNLOAD PLAYLIST")
                    .font(.caption2.weight(.bold)).tracking(1.2)
                    .foregroundStyle(Theme.accent)
                Text(playlist.title).font(.headline).lineLimit(2)
                Text("\(playlist.entries.count) videos")
                    .font(.callout).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("Quality", selection: $selection) {
                    ForEach(Self.choices) { fmt in
                        Text(fmt.label).tag(fmt)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                Text("Each video downloads at the closest available quality.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle(isOn: $includeSubtitles) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Add subtitles")
                    Text(subtitleDetail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(selection == .audioMP3)

            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(destination.lastPathComponent).lineLimit(1)
                Spacer()
                Button("Change…") { pickFolder() }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.surface, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Download \(playlist.entries.count) videos") {
                    // The box can stay checked while switching to MP3: the gate lives here.
                    onConfirm(selection, includeSubtitles && selection != .audioMP3)
                }
                .buttonStyle(WaveButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 430)
        .background(Theme.wash)
    }

    private var subtitleDetail: String {
        if selection == .audioMP3 { return "Not available for MP3" }
        return "Embedded when a video has creator subtitles"
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }
}
