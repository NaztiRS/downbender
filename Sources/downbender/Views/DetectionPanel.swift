import DownbenderCore
import SwiftUI

/// Shown for ambiguous items: offer the media path and always a "download as-is" escape.
/// If a probe already produced qualities (generic extractor), list them; otherwise offer a
/// plain "Process with yt-dlp" that triggers the probe.
struct DetectionPanel: View {
    let title: String
    let info: DirectFileInfo
    let probe: ProbeResult? // non-nil for generic-extractor results
    var isInsecureHTTP: Bool = false
    @Binding var destination: URL
    var onProcessMedia: () -> Void // media file (.mp4) with no probe yet
    var onChooseFormat: (DownloadFormat) -> Void // generic-extractor: user picked a quality
    var onDownloadAsFile: () -> Void
    var onCancel: () -> Void
    var onRemove: () -> Void

    @State private var selection: DownloadFormat?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("HOW SHOULD WE DOWNLOAD THIS?")
                        .font(.caption2.weight(.bold)).tracking(1.2)
                        .foregroundStyle(Theme.accent)
                    Text(title).font(.headline).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Remove from list")
            }
            if let probe, !probe.availableFormats.isEmpty {
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
                .onAppear { selection = probe.availableFormats.first }
            }
            Button(action: onDownloadAsFile) {
                Label("Other — download the file as-is\(info.sizeBytes.map { " (\($0.formatted(.byteCount(style: .file))))" } ?? "")",
                      systemImage: "arrow.down.doc")
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            if isInsecureHTTP {
                Label("\"As-is\" over http isn't encrypted — download only if you trust it.",
                      systemImage: "lock.open")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                if probe == nil {
                    Button("Process with yt-dlp", action: onProcessMedia)
                        .buttonStyle(WaveButtonStyle())
                } else {
                    Button("Download") { if let selection { onChooseFormat(selection) } }
                        .buttonStyle(WaveButtonStyle())
                        .disabled(selection == nil)
                }
            }
        }
        .padding(22)
        .frame(width: 430)
        .background(Theme.wash)
    }
}
