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
        HStack(spacing: 12) {
            primaryArea
            trailingButtons
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isActive ? Theme.accent.opacity(0.72) : Theme.border,
                    lineWidth: 1
                )
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(stateColor)
                .frame(width: 2)
                .padding(.vertical, 5)
        }
        .contentShape(Rectangle())
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

    @ViewBuilder private var primaryArea: some View {
        Group {
            if hasPrimaryAction {
                Button(action: primaryAction) {
                    rowSummary
                }
                .buttonStyle(.plain)
                .help(primaryActionLabel)
                .accessibilityLabel(item.title)
                .accessibilityValue(accessibilityStatus)
                .accessibilityHint(primaryActionHint)
            } else {
                rowSummary
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.title)
                    .accessibilityValue(accessibilityStatus)
            }
        }
        .modifier(DeliveredFileDragModifier(fileURL: draggableFileURL))
    }

    private var rowSummary: some View {
        HStack(spacing: 12) {
            thumbnail
                // Sheets on separate nodes (project pattern) avoid collisions with the row's other sheets.
                .sheet(isPresented: Binding(
                    get: { deleteError != nil },
                    set: { if !$0 { deleteError = nil } }
                )) {
                    ErrorDetailSheet(title: "Couldn't delete", message: deleteError ?? "", onClose: { deleteError = nil })
                }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .lineLimit(1)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                    if let format = item.format { formatChip(format) }
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 6, height: 6)
                    Text(stateLabel)
                        .foregroundStyle(stateColor)
                    Spacer(minLength: 8)
                    Text(sourceLabel)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.35)
                if showsBar {
                    WaveProgress(
                        fraction: item.state == .probing || (item.state == .downloading && item.indeterminateProgress)
                            ? nil : barFraction,
                        pulsing: item.state == .merging,
                        dimmed: item.state == .paused,
                        updatesFrequently: item.state == .probing || item.state == .downloading
                    )
                }
                Text(statusLine)
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(captionColor)
                    .textSelection(.enabled)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var chooserSheet: some View {
        switch item.source {
        case .media:
            if let probe = item.probe {
                FormatPanel(
                    probe: probe,
                    preferred: model.defaultQuality,
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
                .frame(width: 76, height: 46)
                .clipShape(.rect(cornerRadius: 5))
            } else {
                fallbackIcon
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.border))
        .overlay(alignment: .bottomTrailing) {
            if let seconds = item.probe?.durationSeconds, item.format != .audioMP3 {
                Text(durationLabel(seconds))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Theme.canvas.opacity(0.88), in: .rect(cornerRadius: 3))
                    .padding(3)
            }
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: fallbackSymbol)
            .font(.title3)
            .foregroundStyle(Theme.accent.opacity(0.82))
            .frame(width: 76, height: 46)
            .background(Theme.raised, in: .rect(cornerRadius: 5))
    }

    private var fallbackSymbol: String {
        switch item.source {
        case .media: item.format == .audioMP3 ? "music.note" : "film"
        case .directFile, .ambiguous: FileIcon.symbol(for: item.title)
        }
    }

    private func formatChip(_ format: DownloadFormat) -> some View {
        Text(format.label)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.raised, in: .rect(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
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
            iconButton("pause.circle.fill", .secondary, "Pause") { model.queue.pause(item) }
            iconButton("xmark.circle.fill", .tertiary, "Cancel") { model.queue.cancel(item) }
        case .paused:
            iconButton("play.circle.fill", .tint, "Resume") { model.queue.resume(item) }
            iconButton("xmark.circle.fill", .tertiary, "Cancel") { model.queue.cancel(item) }
        case .done:
            iconButton("xmark.circle.fill", .tertiary, "Remove from list") { model.remove(item) }
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
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Theme.raised, in: .rect(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Theme.border)
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(style)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Shows the full error text, selectable, since the caption truncates it.
    private func infoButton(message: String, title: String) -> some View {
        Button { showingError = true } label: { Image(systemName: "info.circle").font(.title3) }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Show full error")
            .accessibilityLabel("Show full error")
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
            Button("Pause") { model.queue.pause(item) }
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

    private var stateLabel: String {
        switch item.state {
        case .probing: "ANALYZING"
        case .probeFailed: "ANALYSIS_ERROR"
        case .readyToChoose: "AWAITING_INPUT"
        case .queued: "QUEUED"
        case .downloading: "ACTIVE"
        case .merging: "FINALIZING"
        case .paused: "PAUSED"
        case .done: "DONE"
        case .failed: "FAILED"
        case .cancelled: "CANCELLED"
        }
    }

    private var stateColor: Color {
        switch item.state {
        case .probeFailed, .failed: Theme.danger
        case .paused: Theme.warning
        case .done: Theme.success
        case .cancelled: Theme.muted
        case .probing, .readyToChoose, .queued, .downloading, .merging: Theme.accent
        }
    }

    private var sourceLabel: String {
        let host = URL(string: item.url)?.host?
            .replacingOccurrences(of: "www.", with: "")
            .uppercased()
        let kind = switch item.source {
        case .media: "MEDIA"
        case .directFile: "DIRECT"
        case .ambiguous: "DETECT"
        }
        return [host, kind].compactMap { $0 }.joined(separator: " / ")
    }

    private var hasPrimaryAction: Bool {
        item.state == .readyToChoose || item.state == .done
    }

    private var primaryActionLabel: String {
        switch item.state {
        case .readyToChoose:
            switch item.source {
            case .media: "Choose quality"
            case .directFile: "Review download"
            case .ambiguous: "Choose download method"
            }
        case .done: "Show in Finder"
        default: ""
        }
    }

    private var primaryActionHint: String {
        switch item.state {
        case .readyToChoose: "Opens the download options"
        case .done: "Reveals the downloaded file in Finder"
        default: ""
        }
    }

    private var accessibilityStatus: String {
        switch item.state {
        case .readyToChoose:
            switch item.source {
            case .media: return "Awaiting quality selection"
            case .directFile: return "Awaiting download review"
            case .ambiguous: return "Awaiting download method"
            }
        case .downloading where item.indeterminateProgress:
            return "Downloading, progress unknown"
        default:
            return statusLine
        }
    }

    private var draggableFileURL: URL? {
        guard item.state == .done, let url = item.deliveredFileURL,
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
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
        case .probeFailed, .failed: return Theme.danger
        case .readyToChoose: return Theme.accent
        case .paused: return Theme.warning
        case .done where item.deliveredMismatch: return Theme.warning
        case .done: return Theme.success
        default: return Theme.muted
        }
    }

}

private struct DeliveredFileDragModifier: ViewModifier {
    let fileURL: URL?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let fileURL {
            content.draggable(fileURL)
        } else {
            content
        }
    }
}
