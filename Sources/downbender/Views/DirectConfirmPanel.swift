import DownbenderCore
import SwiftUI

/// Mini-confirmation for a plain-file download: name + size + folder, one "Download" button.
struct DirectConfirmPanel: View {
    let title: String
    let info: DirectFileInfo
    var isInsecureHTTP: Bool = false
    @Binding var destination: URL
    var onDownload: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("DOWNLOAD FILE")
                    .font(.caption2.weight(.bold)).tracking(1.2)
                    .foregroundStyle(Theme.accent)
                HStack(spacing: 8) {
                    Image(systemName: FileIcon.symbol(for: title)).foregroundStyle(Theme.accent)
                    Text(title).font(.headline).lineLimit(2)
                }
                Text(sizeLine).font(.callout).foregroundStyle(.secondary)
                if FileIcon.isExecutable(title) {
                    Label("This is an app or installer — macOS will check it when you open it.",
                          systemImage: "exclamationmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if isInsecureHTTP {
                    Label("This link isn't encrypted (http). Download only if you trust it.",
                          systemImage: "lock.open")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            folderRow
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Download", action: onDownload)
                    .buttonStyle(WaveButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 430)
        .background(Theme.wash)
    }

    private var sizeLine: String {
        guard let bytes = info.sizeBytes else { return "Size unknown" }
        return bytes.formatted(.byteCount(style: .file))
    }

    private var folderRow: some View {
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
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }
}

/// Extension→SF Symbol mapping shared by the panel and the queue row.
enum FileIcon {
    static func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "iso", "img": "doc.zipper"
        case "pdf": "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg": "photo"
        case "dmg", "pkg", "app", "exe", "msi", "deb", "rpm", "apk": "shippingbox"
        case "mp4", "mkv", "webm", "mov", "m4v": "film"
        case "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus": "music.note"
        default: "doc"
        }
    }

    static func isExecutable(_ name: String) -> Bool {
        ["dmg", "pkg", "app", "exe", "msi", "deb", "rpm", "apk"].contains((name as NSString).pathExtension.lowercased())
    }
}
