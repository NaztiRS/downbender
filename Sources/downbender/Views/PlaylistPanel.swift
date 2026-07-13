import SwiftUI
import DownbenderCore

/// One choice for the whole playlist. The size estimate is instant (duration-based) and a
/// small background sample refines it silently; nothing here ever makes the user wait.
struct PlaylistPanel: View {
    let analysis: PlaylistAnalysis
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
            HStack(alignment: .center, spacing: 14) {
                thumbnailFan
                VStack(alignment: .leading, spacing: 3) {
                    Text("DOWNLOAD PLAYLIST")
                        .font(.caption2.weight(.bold)).tracking(1.2)
                        .foregroundStyle(Theme.accent)
                    Text(analysis.playlist.title).font(.headline).lineLimit(2)
                    Text(summary)
                        .font(.callout).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
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
                Button("Download \(analysis.playlist.entries.count) videos") {
                    // The box can stay checked while switching to MP3: the gate lives here.
                    onConfirm(selection, includeSubtitles && selection != .audioMP3)
                }
                .buttonStyle(WaveButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Theme.wash)
    }

    /// Fanned covers of the first entries: instantly says "this is a stack of videos".
    private var thumbnailFan: some View {
        let covers = analysis.playlist.entries.prefix(3).compactMap(\.thumbnailURL)
        return ZStack {
            ForEach(Array(covers.enumerated()), id: \.offset) { index, url in
                // Back covers peek out behind the front one, fanned like a hand of cards.
                let spread = Double(index) - Double(covers.count - 1) / 2
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Theme.surface)
                }
                .frame(width: 76, height: 44)
                .clipShape(.rect(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline))
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .rotationEffect(.degrees(spread * 7))
                .offset(x: spread * 16, y: abs(spread) * 3)
                .zIndex(-abs(spread))
            }
        }
        .frame(width: 110, height: 56)
    }

    /// "129 videos · ~4.3 GB" — instant, refined silently as the sample calibrates.
    private var summary: String {
        var parts = ["\(analysis.playlist.entries.count) videos"]
        if let bytes = analysis.estimatedTotalBytes(for: selection) {
            parts.append("~\(bytes.formatted(.byteCount(style: .file)))")
        }
        return parts.joined(separator: " · ")
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
