import SwiftUI
import DownbenderCore

struct FormatPanel: View {
    let probe: ProbeResult
    @Binding var destination: URL
    var onConfirm: (DownloadFormat) -> Void
    var onCancel: () -> Void

    @State private var selection: DownloadFormat?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("CHOOSE QUALITY")
                    .font(.caption2.weight(.bold)).tracking(1.2)
                    .foregroundStyle(Theme.accent)
                Text(probe.title).font(.headline).lineLimit(2)
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
                Button("Download") {
                    if let selection { onConfirm(selection) }
                }
                .buttonStyle(WaveButtonStyle())
                .disabled(selection == nil)
            }
        }
        .padding(22)
        .frame(width: 430)
        .background(Theme.wash)
        .onAppear {
            selection = probe.availableFormats.first(where: {
                if case .video(let h) = $0 { return h <= 1080 }
                return false
            }) ?? probe.availableFormats.first
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }
}
