import AppKit
import SwiftUI
import DownbenderCore

@MainActor
struct DownbenderMenuBarIcon: View {
    var size: CGFloat = 10

    private static let image: NSImage = {
        if let vectorURL = Bundle.main.url(
            forResource: "DownbenderMenuBar",
            withExtension: "svg"
        ), let vectorImage = NSImage(contentsOf: vectorURL) {
            // MenuBarExtra measures the NSImage's intrinsic AppKit size before
            // applying SwiftUI's frame. Keep the vector representation, but give
            // it status-item dimensions so macOS does not lay it out off-screen.
            vectorImage.size = NSSize(width: 16, height: 16)
            vectorImage.isTemplate = true
            return vectorImage
        }

        let resourceURLs = [
            Bundle.main.url(
                forResource: "icon-32",
                withExtension: "png",
                subdirectory: "ChromeExtension/icons"
            ),
            Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
        ]

        return resourceURLs
            .compactMap { $0 }
            .compactMap(NSImage.init(contentsOf:))
            .first ?? NSApplication.shared.applicationIconImage
    }()

    var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct MenuBarQueueLabel: View {
    @Bindable var systemSurfaceQueue: SystemSurfaceQueueState

    var body: some View {
        let summary = systemSurfaceQueue.snapshot
        Label {
            Text(statusLabel(summary))
        } icon: {
            DownbenderMenuBarIcon()
        }
        .accessibilityLabel("Downbender")
        .accessibilityValue(accessibilityStatus(summary))
    }

    private func statusLabel(_ summary: QueueActivitySnapshot) -> String {
        if summary.activeCount > 0 { return activeLabel(summary) }
        if summary.pausedCount > 0 { return "\(summary.pausedCount)" }
        if summary.failedCount > 0 { return "\(summary.failedCount)" }
        return "Downbender"
    }

    private func activeLabel(_ summary: QueueActivitySnapshot) -> String {
        guard let percent = summary.progressPercent else {
            return "\(summary.activeCount)"
        }
        return "\(percent)%"
    }

    private func accessibilityStatus(_ summary: QueueActivitySnapshot) -> String {
        if summary.activeCount > 0 {
            guard let percent = summary.progressPercent else {
                return "\(summary.activeCount) active, progress unavailable"
            }
            return "\(summary.activeCount) active, \(percent) percent"
        }
        if summary.pausedCount > 0 { return "\(summary.pausedCount) paused" }
        if summary.failedCount > 0 { return "\(summary.failedCount) failed" }
        return "Idle"
    }
}

struct MenuBarQueueView: View {
    @Bindable var model: AppModel
    @Bindable var notifier: DownloadNotifier
    @Bindable var systemSurfaceQueue: SystemSurfaceQueueState
    @Environment(\.openWindow) private var openWindow

    private var summary: QueueActivitySnapshot { systemSurfaceQueue.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let notice = notifier.currentNotice {
                completionNotice(notice)
                Divider()
            }

            if model.queue.items.isEmpty {
                ContentUnavailableView(
                    "No downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Paste or drop a link in Downbender to begin.")
                )
                .frame(maxWidth: .infinity, minHeight: 130)
            } else {
                queueItems
            }

            Divider()
            controls
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 10) {
            DownbenderMenuBarIcon(size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Downbender").font(.headline)
                Text(summaryText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let percent = summary.progressPercent {
                Text("\(percent)%")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var queueItems: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(model.queue.items) { item in
                    queueItem(item)
                }
            }
        }
        .frame(maxHeight: 280)
    }

    private func queueItem(_ item: DownloadItem) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol(for: item))
                .foregroundStyle(color(for: item))
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(status(for: item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if showsProgress(item) {
                    ProgressView(value: progress(for: item))
                        .progressViewStyle(.linear)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.title)
            .accessibilityValue(status(for: item))
            Spacer(minLength: 4)
            if item.state == .done {
                Button {
                    reveal(item)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
                .accessibilityLabel("Show \(item.title) in Finder")
            }
        }
        .padding(9)
        .background(Theme.surface, in: .rect(cornerRadius: 9))
        .accessibilityElement(children: .contain)
    }

    private func completionNotice(_ notice: CompletionNotice) -> some View {
        HStack(spacing: 9) {
            Image(systemName: notice.symbol)
                .foregroundStyle(notice.success ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.heading).font(.caption.weight(.semibold))
                Text(notice.title).font(.caption2).lineLimit(1)
            }
            Spacer()
            Button(notice.actionTitle) {
                notifier.performPrimaryAction(for: notice)
            }
            .controlSize(.small)
            Button {
                notifier.dismissAll()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss notification")
        }
        .padding(9)
        .background(Theme.surface, in: .rect(cornerRadius: 9))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    showMainWindow()
                } label: {
                    Label("Open Downbender", systemImage: "macwindow")
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(model.destination)
                } label: {
                    Label("Downloads", systemImage: "folder")
                }
            }

            if model.queue.cancellableCount > 0 {
                HStack {
                    Button("Pause all") { model.queue.pauseAllActive() }
                        .disabled(model.queue.pausableCount == 0)
                    Button("Resume all") { model.queue.resumeAllPaused() }
                        .disabled(model.queue.resumableCount == 0)
                    Spacer()
                    Button("Clear finished") { model.queue.clearSettled() }
                        .disabled(!model.queue.hasSettledItems)
                }
            } else if model.queue.hasSettledItems {
                HStack {
                    Spacer()
                    Button("Clear finished") { model.queue.clearSettled() }
                }
            }
        }
        .controlSize(.small)
    }

    private var summaryText: String {
        var parts: [String] = []
        if summary.runningCount > 0 { parts.append("\(summary.runningCount) downloading") }
        if summary.queuedCount > 0 { parts.append("\(summary.queuedCount) queued") }
        if summary.analyzingCount > 0 { parts.append("\(summary.analyzingCount) analyzing") }
        if summary.choosingCount > 0 { parts.append("\(summary.choosingCount) awaiting choice") }
        if summary.pausedCount > 0 { parts.append("\(summary.pausedCount) paused") }
        if parts.isEmpty, summary.failedCount > 0 { parts.append("\(summary.failedCount) failed") }
        if parts.isEmpty { return "Idle" }
        return parts.joined(separator: " · ")
    }

    private func showMainWindow() {
        openWindow(id: "main")
        bringMainWindowForward()
    }

    private func reveal(_ item: DownloadItem) {
        switch model.revealOutcome(for: item) {
        case .reveal(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .openFolder(let folder):
            NSWorkspace.shared.open(folder)
        case .missing:
            showMainWindow()
            showMissingFileAlert(item)
        }
    }

    private func showMissingFileAlert(_ item: DownloadItem) {
        let alert = NSAlert()
        alert.messageText = "File not found"
        alert.informativeText = "“\(item.title)” may have been moved or deleted."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func status(for item: DownloadItem) -> String {
        switch item.state {
        case .probing: "Analyzing…"
        case .probeFailed: "Analysis failed"
        case .readyToChoose: "Awaiting your choice"
        case .queued: "Queued"
        case .downloading where item.indeterminateProgress: "Downloading…"
        case .downloading: "\(Int((item.fraction * 100).rounded()))% downloaded"
        case .merging: "Finalizing…"
        case .paused: "Paused at \(Int((item.fraction * 100).rounded()))%"
        case .done: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    private func symbol(for item: DownloadItem) -> String {
        switch item.state {
        case .probing: "magnifyingglass"
        case .probeFailed, .failed: "exclamationmark.triangle.fill"
        case .readyToChoose: "slider.horizontal.3"
        case .queued: "clock"
        case .downloading: "arrow.down.circle.fill"
        case .merging: "sparkles"
        case .paused: "pause.circle.fill"
        case .done: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private func color(for item: DownloadItem) -> Color {
        switch item.state {
        case .probeFailed, .failed: .orange
        case .done: .green
        case .cancelled: .secondary
        default: Theme.accent
        }
    }

    private func showsProgress(_ item: DownloadItem) -> Bool {
        switch item.state {
        case .queued, .downloading, .merging, .paused: true
        default: false
        }
    }

    private func progress(for item: DownloadItem) -> Double? {
        if item.state == .downloading, item.indeterminateProgress { return nil }
        return min(1, max(0, item.fraction))
    }
}
