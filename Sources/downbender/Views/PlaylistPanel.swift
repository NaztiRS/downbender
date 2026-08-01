import SwiftUI
import DownbenderCore

/// One choice for the whole playlist. The size estimate is instant (duration-based) and a
/// small background sample refines it silently; nothing here ever makes the user wait.
struct PlaylistPanel: View {
    let analysis: PlaylistAnalysis
    @Binding var destination: URL
    var onConfirm: ([PlaylistEntry], DownloadFormat, Bool) -> Void
    var onCancel: () -> Void

    @State private var selection: DownloadFormat = .video(height: 1080)
    @State private var includeSubtitles = false
    @State private var selectedEntryIndices: Set<Int>

    private static let choices: [DownloadFormat] = [
        .maximumVideo,
        .video(height: 2160),
        .video(height: 1440),
        .video(height: 1080),
        .video(height: 720),
        .video(height: 480),
        .video(height: 360),
        .audioMP3,
    ]

    init(
        analysis: PlaylistAnalysis,
        destination: Binding<URL>,
        onConfirm: @escaping ([PlaylistEntry], DownloadFormat, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.analysis = analysis
        self._destination = destination
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self._selectedEntryIndices = State(initialValue: Set(analysis.playlist.entries.indices))
    }

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

            entrySelection

            VStack(alignment: .leading, spacing: 7) {
                Picker("Quality for all videos", selection: $selection) {
                    ForEach(Self.choices) { format in
                        Text("\(format.preferenceLabel) · \(format.containerLabel)")
                            .accessibilityLabel(
                                "\(format.preferenceLabel), \(format.containerLabel) output"
                            )
                            .tag(format)
                    }
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectionDetail)
                    Text(outputSummary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
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
                    .keyboardShortcut(.cancelAction)
                Button(downloadButtonTitle) {
                    // The box can stay checked while switching to MP3: the gate lives here.
                    onConfirm(selectedEntries, selection, includeSubtitles && selection != .audioMP3)
                }
                .buttonStyle(WaveButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(selectedEntries.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 500)
        .background(Theme.wash)
    }

    private var entrySelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("VIDEOS")
                    .font(.caption2.weight(.bold)).tracking(1.1)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Select all") { selectAll() }
                    .disabled(selectedEntryIndices.count == analysis.playlist.entries.count)
                    .accessibilityHint("Includes every video in this playlist")
                Button("Select none") { selectedEntryIndices.removeAll() }
                    .disabled(selectedEntryIndices.isEmpty)
                    .accessibilityHint("Excludes every video in this playlist")
            }
            .buttonStyle(.plain)
            .font(.caption)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(analysis.playlist.entries.indices, id: \.self) { index in
                        entryRow(at: index)
                        if index != analysis.playlist.entries.indices.last {
                            Divider().overlay(Theme.hairline)
                        }
                    }
                }
            }
            .frame(maxHeight: 200)
            .background(Theme.surface, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        }
    }

    private func entryRow(at index: Int) -> some View {
        let entry = analysis.playlist.entries[index]
        return Toggle(isOn: entryBinding(at: index)) {
            HStack(spacing: 10) {
                entryThumbnail(entry)
                    .accessibilityHidden(true)
                Text(entry.title)
                    .font(.callout)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let duration = durationLabel(entry.durationSeconds) {
                    Text(duration)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .accessibilityLabel(
            "Video \(index + 1) of \(analysis.playlist.entries.count), \(entry.title)"
        )
        .accessibilityHint("Include or exclude this video from the playlist download")
    }

    @ViewBuilder private func entryThumbnail(_ entry: PlaylistEntry) -> some View {
        if let url = entry.thumbnailURL {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(Theme.wash)
            }
            .frame(width: 58, height: 34)
            .clipShape(.rect(cornerRadius: 5))
        } else {
            Image(systemName: "video")
                .foregroundStyle(.secondary)
                .frame(width: 58, height: 34)
                .background(Theme.wash, in: .rect(cornerRadius: 5))
        }
    }

    private func entryBinding(at index: Int) -> Binding<Bool> {
        Binding(
            get: { selectedEntryIndices.contains(index) },
            set: { selected in
                if selected { selectedEntryIndices.insert(index) }
                else { selectedEntryIndices.remove(index) }
            }
        )
    }

    private func selectAll() {
        selectedEntryIndices = Set(analysis.playlist.entries.indices)
    }

    private var selectedEntries: [PlaylistEntry] {
        analysis.playlist.entries.enumerated().compactMap { index, entry in
            selectedEntryIndices.contains(index) ? entry : nil
        }
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

    /// Kept separate from the estimate below the picker so the header remains stable.
    private var summary: String {
        let selected = selectedEntries.count
        let total = analysis.playlist.entries.count
        if selected == total {
            return "\(total) \(total == 1 ? "video" : "videos") selected"
        }
        return "\(selected) of \(total) \(total == 1 ? "video" : "videos") selected"
    }

    private var selectionDetail: String {
        switch selection {
        case .maximumVideo:
            return "Downloads the highest available resolution for each video."
        case .video(let height):
            return "Each video uses the closest available resolution at or below \(height)p."
        case .audioMP3:
            return "Extracts the audio from every item as MP3."
        }
    }

    private var outputSummary: String {
        var parts = ["\(selection.containerLabel) output"]
        if selectedEntries.isEmpty {
            parts.append("select at least one video")
        } else if let bytes = analysis.estimatedTotalBytes(for: selection, selectedEntries: selectedEntries) {
            parts.append("estimated total ~\(bytes.formatted(.byteCount(style: .file)))")
        } else {
            parts.append("size estimate unavailable")
        }
        return parts.joined(separator: " · ")
    }

    private var subtitleDetail: String {
        if selection == .audioMP3 { return "Not available for MP3" }
        return "Embedded when a video has creator subtitles"
    }

    private var downloadButtonTitle: String {
        let count = selectedEntries.count
        return "Download \(count) \(count == 1 ? "video" : "videos")"
    }

    private func durationLabel(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = total % 3_600 / 60
        let remainingSeconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }
}
