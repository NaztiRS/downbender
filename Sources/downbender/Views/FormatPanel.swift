import SwiftUI
import DownbenderCore

struct FormatPanel: View {
    let probe: ProbeResult
    var preferred: DownloadFormat?
    @Binding var destination: URL
    var onConfirm: (DownloadFormat, Bool) -> Void
    var onCancel: () -> Void
    var onRemove: () -> Void

    @State private var selection: DownloadFormat?
    @State private var includeSubtitles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CHOOSE QUALITY")
                        .font(.caption2.weight(.bold)).tracking(1.2)
                        .foregroundStyle(Theme.accent)
                    Text(probe.title).font(.headline).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Remove from list")
            }

            Picker("Quality", selection: $selection) {
                ForEach(probe.availableFormats) { fmt in
                    if let bytes = probe.approxSizeBytes[fmt] {
                        Text("\(fmt.label) · ~\(bytes.formatted(.byteCount(style: .file)))").tag(Optional(fmt))
                    } else {
                        Text(fmt.label).tag(Optional(fmt))
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)

            Toggle(isOn: $includeSubtitles) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Add subtitles")
                    Text(subtitleDetail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!subtitlesSelectable)

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
                Button("Download") {
                    // The box can stay checked while switching to MP3: the gate lives here.
                    if let selection { onConfirm(selection, includeSubtitles && subtitlesSelectable) }
                }
                .buttonStyle(WaveButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(22)
        .frame(width: 430)
        .background(Theme.wash)
        .onAppear {
            selection = preferred.flatMap { probe.closestMatch(to: $0) }
                ?? probe.availableFormats.first(where: {
                    if case .video(let h) = $0 { return h <= 1080 }
                    return false
                }) ?? probe.availableFormats.first
        }
    }

    private var subtitlesSelectable: Bool {
        !probe.subtitleLanguages.isEmpty && selection != .audioMP3
    }

    private var subtitleDetail: String {
        if probe.subtitleLanguages.isEmpty { return "No subtitles available" }
        if selection == .audioMP3 { return "Not available for MP3" }
        let langs = probe.subtitleLanguages
        let shown = langs.prefix(6).joined(separator: ", ")
        return langs.count > 6 ? "\(shown), …" : shown
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }
}
