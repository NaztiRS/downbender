import SwiftUI
import DownbenderCore

struct QueueRow: View {
    let item: DownloadItem
    @Bindable var model: AppModel
    @State private var showingError = false
    @State private var choosing = false
    @State private var confirmingDelete = false
    @State private var deleteError: String?
    @State private var fileMissing = false

    var body: some View {
        HStack(spacing: 14) {
            thumbnail
                // Sheets on separate nodes (project pattern) avoid collisions with the row's other sheets.
                .sheet(isPresented: Binding(
                    get: { deleteError != nil },
                    set: { if !$0 { deleteError = nil } }
                )) {
                    ErrorDetailSheet(title: "Couldn't delete", message: deleteError ?? "", onClose: { deleteError = nil })
                }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.title).lineLimit(1).font(.body.weight(.medium))
                    Spacer(minLength: 0)
                    if let format = item.format { formatChip(format) }
                }
                if showsBar {
                    WaveProgress(
                        fraction: item.state == .probing ? nil : barFraction,
                        pulsing: item.state == .merging,
                        dimmed: item.state == .paused
                    )
                }
                Text(statusLine).font(.caption)
                    .foregroundStyle(captionColor)
                    .textSelection(.enabled)
                    .lineLimit(1)
            }
            trailingButtons
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surfaceDepth))
        .overlay(
            // Glass rim (lit top edge); active rows switch to the accent border.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isActive ? AnyShapeStyle(Theme.accent.opacity(0.55)) : AnyShapeStyle(Theme.rim),
                    lineWidth: isActive ? 1.5 : 1
                )
        )
        .shadow(color: isActive ? Theme.glow.opacity(0.18) : .black.opacity(0.25), radius: isActive ? 10 : 6, y: 3)
        // Buttons take priority over onTapGesture in SwiftUI, so this gesture doesn't steal their clicks.
        .contentShape(Rectangle())
        .onTapGesture(perform: primaryAction)
        .help(helpText)
        .sheet(isPresented: $choosing) {
            chooserSheet
        }
        .confirmationDialog(
            "Delete “\(item.title)” permanently?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete file", role: .destructive) { deleteFile() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file will be removed from disk, bypassing the Trash.")
        }
        .alert("File not found", isPresented: $fileMissing) {
            Button("Remove from list") { model.remove(item) }
            Button("OK", role: .cancel) {}
        } message: {
            Text("“\(item.title)” is no longer on disk. It may have been moved or deleted.")
        }
        .contextMenu { contextMenuItems }
    }

    @ViewBuilder private var chooserSheet: some View {
        switch item.source {
        case .media:
            if let probe = item.probe {
                FormatPanel(
                    probe: probe,
                    destination: $model.destination,
                    onConfirm: { format, includeSubtitles in
                        model.choose(format, includeSubtitles: includeSubtitles, for: item)
                        choosing = false
                    },
                    onCancel: { choosing = false },
                    onRemove: removeFromChooser
                )
            }
        case .directFile(let info):
            DirectConfirmPanel(
                title: item.title, info: info, isInsecureHTTP: model.isInsecureHTTP(item), destination: $model.destination,
                onDownload: {
                    if model.isInsecureHTTP(item) { model.confirmInsecureHTTP(item) }
                    model.confirmDirect(item); choosing = false
                },
                onCancel: { choosing = false }
            )
        case .ambiguous(let info):
            DetectionPanel(
                title: item.title, info: info, probe: item.probe, isInsecureHTTP: model.isInsecureHTTP(item),
                destination: $model.destination,
                onProcessMedia: { model.processAmbiguousAsMedia(item); choosing = false },
                onChooseFormat: { fmt in model.choose(fmt, for: item); choosing = false },
                onDownloadAsFile: {
                    if model.isInsecureHTTP(item) { model.confirmInsecureHTTP(item) }
                    model.downloadAmbiguousAsFile(item); choosing = false
                },
                onCancel: { choosing = false },
                onRemove: removeFromChooser
            )
        }
    }

    private func removeFromChooser() {
        choosing = false
        model.remove(item)
    }

    // MARK: - Thumbnail

    private var thumbnail: some View {
        Group {
            if let url = item.thumbnailURL {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    fallbackIcon
                }
                .frame(width: 84, height: 48)
                .clipShape(.rect(cornerRadius: 8))
            } else {
                fallbackIcon
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        .overlay(alignment: .bottomTrailing) {
            if let seconds = item.probe?.durationSeconds, item.format != .audioMP3 {
                Text(durationLabel(seconds))
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.65), in: .rect(cornerRadius: 4))
                    .padding(3)
            }
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: fallbackSymbol)
            .font(.title3)
            .foregroundStyle(Theme.accent.opacity(0.7))
            .frame(width: 84, height: 48)
            .background(Theme.surface, in: .rect(cornerRadius: 8))
    }

    private var fallbackSymbol: String {
        switch item.source {
        case .media: item.format == .audioMP3 ? "music.note" : "film"
        case .directFile, .ambiguous: FileIcon.symbol(for: item.title)
        }
    }

    private func formatChip(_ format: DownloadFormat) -> some View {
        Text(format.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Theme.surface, in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.hairline))
    }

    // MARK: - Per-state buttons

    @ViewBuilder private var trailingButtons: some View {
        switch item.state {
        case .probing:
            iconButton("xmark.circle.fill", .tertiary, "Discard") { model.remove(item) }
        case .probeFailed(let msg):
            iconButton("arrow.clockwise.circle.fill", .secondary, "Retry analysis") { model.retryProbe(item) }
            infoButton(message: msg, title: "Analysis error")
            iconButton("xmark.circle.fill", .tertiary, "Remove from list") { model.remove(item) }
        case .readyToChoose:
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            iconButton("xmark.circle.fill", .tertiary, "Remove from list") { model.remove(item) }
        case .queued, .downloading:
            iconButton("pause.circle.fill", .secondary, "Pause") { model.queue.pause(item) }
            iconButton("xmark.circle.fill", .tertiary, "Cancel") { model.queue.cancel(item) }
        case .merging:
            iconButton("xmark.circle.fill", .tertiary, "Cancel") { model.queue.cancel(item) }
        case .paused:
            iconButton("play.circle.fill", .tint, "Resume") { model.queue.resume(item) }
            iconButton("xmark.circle.fill", .tertiary, "Cancel") { model.queue.cancel(item) }
        case .done:
            EmptyView()
        case .failed(let msg):
            iconButton("arrow.clockwise.circle.fill", .secondary, "Retry") { model.queue.retry(item) }
            infoButton(message: msg, title: "Download error")
            iconButton("xmark.circle.fill", .tertiary, "Remove from list") { model.remove(item) }
        case .cancelled:
            iconButton("arrow.clockwise.circle.fill", .secondary, "Retry") { model.queue.retry(item) }
            iconButton("xmark.circle.fill", .tertiary, "Remove from list") { model.remove(item) }
        }
    }

    private func iconButton<S: ShapeStyle>(_ symbol: String, _ style: S, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.title3) }
            .buttonStyle(.plain)
            .foregroundStyle(style)
            .help(help)
    }

    /// Shows the full error text, selectable, since the caption truncates it.
    private func infoButton(message: String, title: String) -> some View {
        Button { showingError = true } label: { Image(systemName: "info.circle").font(.title3) }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .sheet(isPresented: $showingError) {
                ErrorDetailSheet(title: title, message: message, onClose: { showingError = false })
            }
    }

    // MARK: - Context menu

    @ViewBuilder private var contextMenuItems: some View {
        switch item.state {
        case .probing:
            Button("Remove from list") { model.remove(item) }
        case .probeFailed:
            Button("Retry analysis") { model.retryProbe(item) }
            Button("Remove from list") { model.remove(item) }
        case .readyToChoose:
            Button("Choose quality…") { choosing = true }
            Button("Remove from list") { model.remove(item) }
        case .queued, .downloading:
            Button("Pause") { model.queue.pause(item) }
            Button("Cancel") { model.queue.cancel(item) }
        case .merging:
            Button("Cancel") { model.queue.cancel(item) }
        case .paused:
            Button("Resume") { model.queue.resume(item) }
            Button("Cancel") { model.queue.cancel(item) }
        case .done:
            Button("Show in Finder") { revealInFinder() }
            Button("Remove from list") { model.remove(item) }
            Button("Delete file…", role: .destructive) { confirmingDelete = true }
        case .failed, .cancelled:
            Button("Retry") { model.queue.retry(item) }
            Button("Remove from list") { model.remove(item) }
        }
    }

    // MARK: - Actions

    private func primaryAction() {
        switch item.state {
        case .readyToChoose: choosing = true
        case .done: revealInFinder()
        default: break
        }
    }

    private func revealInFinder() {
        switch model.revealOutcome(for: item) {
        case .reveal(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
        case .openFolder(let folder): NSWorkspace.shared.open(folder)
        case .missing: fileMissing = true
        }
    }

    private func deleteFile() {
        do { try model.deleteFile(of: item) }
        catch { deleteError = error.localizedDescription }
    }

    // MARK: - Presentation

    private var showsBar: Bool {
        switch item.state {
        case .probing, .queued, .downloading, .merging, .paused, .done: return true
        case .readyToChoose, .probeFailed, .failed, .cancelled: return false
        }
    }

    private var isActive: Bool {
        item.state == .downloading || item.state == .merging
    }

    private var barFraction: Double? {
        switch item.state {
        case .done: return 1
        default: return item.fraction
        }
    }

    /// yt-dlp prepends walls of WARNINGs to the real error: surface the definitive "ERROR:" line.
    private func compactError(_ message: String) -> String {
        if let hint = YtdlpErrorHint.friendly(message) { return hint }
        let lines = message.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.last(where: { $0.hasPrefix("ERROR") }) ?? lines.first ?? message
    }

    private func durationLabel(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    private var statusLine: String {
        switch item.state {
        case .probing: return "Analyzing…"
        case .probeFailed(let m): return "Analysis error: \(compactError(m))"
        case .readyToChoose:
            switch item.source {
            case .media: return "Click to choose quality"
            case .directFile: return "Click to review and download"
            case .ambiguous: return "Click to choose how to download"
            }
        case .queued: return "Queued"
        case .downloading:
            let pct = "\(Int(item.fraction * 100))%"
            return ([pct] + [item.speedText, item.etaText].filter { !$0.isEmpty }).joined(separator: " · ")
        case .merging: return "Finalizing…"
        case .paused: return "Paused · \(Int(item.fraction * 100))%"
        case .done:
            if item.deliveredMismatch { return item.deliveredNote }
            return "Done" + (item.deliveredNote.isEmpty ? "" : " · \(item.deliveredNote)")
        case .failed(let m): return "Error: \(compactError(m))"
        case .cancelled: return "Cancelled"
        }
    }

    private var captionColor: Color {
        switch item.state {
        case .probeFailed, .failed: return .orange
        case .readyToChoose: return Theme.accent
        case .done where item.deliveredMismatch: return .orange
        default: return .secondary
        }
    }

    private var helpText: String {
        switch item.state {
        case .done: return "Click to show in Finder"
        case .readyToChoose: return "Click to choose quality"
        default: return ""
        }
    }
}
