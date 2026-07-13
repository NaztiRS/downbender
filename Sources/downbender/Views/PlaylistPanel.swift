import SwiftUI
import DownbenderCore

/// One choice for the whole playlist. Opens instantly (loading state) while the entry list
/// resolves; a background estimation then refines "N videos · ~total" live, so the user can
/// confirm at any moment without waiting for analysis.
struct PlaylistPanel: View {
    let analysis: PlaylistAnalysis
    @Binding var destination: URL
    var onConfirm: (DownloadFormat, Bool) -> Void
    var onCancel: () -> Void
    var onRetry: () -> Void

    @State private var selection: DownloadFormat = .video(height: 1080)
    @State private var includeSubtitles = false

    private static let choices: [DownloadFormat] = [
        .video(height: 1080), .video(height: 720), .video(height: 480), .video(height: 360), .audioMP3,
    ]

    var body: some View {
        Group {
            if let failure = analysis.failure {
                failureContent(failure)
            }
            else if let playlist = analysis.playlist {
                panelContent(playlist)
            }
            else {
                loadingContent
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Theme.wash)
    }

    private var loadingContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DOWNLOAD PLAYLIST")
                .font(.caption2.weight(.bold)).tracking(1.2)
                .foregroundStyle(Theme.accent)
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Analyzing playlist…").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }

    private func failureContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Could not load playlist", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Retry", action: onRetry)
                    .buttonStyle(WaveButtonStyle())
            }
        }
    }

    private func panelContent(_ playlist: PlaylistProbe) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("DOWNLOAD PLAYLIST")
                    .font(.caption2.weight(.bold)).tracking(1.2)
                    .foregroundStyle(Theme.accent)
                Text(playlist.title).font(.headline).lineLimit(2)
                Text(summary(playlist))
                    .font(.callout).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
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
    }

    /// "44 videos · ~3.2 GB so far · analyzing 21/44…" — refines live, never blocks.
    private func summary(_ playlist: PlaylistProbe) -> String {
        var parts = ["\(playlist.entries.count) videos"]
        if selection != .audioMP3, let estimate = analysis.estimatedTotalBytes(for: selection) {
            let formatted = estimate.bytes.formatted(.byteCount(style: .file))
            parts.append(estimate.sizedVideos < playlist.entries.count ? "~\(formatted) so far" : "~\(formatted)")
        }
        if analysis.analyzedCount < playlist.entries.count {
            parts.append("analyzing \(analysis.analyzedCount)/\(playlist.entries.count)…")
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
