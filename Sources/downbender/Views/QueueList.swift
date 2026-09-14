import SwiftUI
import DownbenderCore

struct QueueList: View {
    @Bindable var model: AppModel
    @State private var confirmingCancelAll = false
    @State private var selectedFilters: Set<QueueFilter> = []
    @State private var retryingAllChannel: YtdlpEngineChannel?
    @State private var bulkRetryError: String?

    var body: some View {
        Group {
            if model.queue.items.isEmpty {
                emptyState
            } else {
                GeometryReader { proxy in
                    if proxy.size.width >= 780 {
                        HStack(spacing: 0) {
                            summaryRail
                                .frame(width: 164)
                            Rectangle()
                                .fill(Theme.border)
                                .frame(width: 1)
                            queueColumn(showsCompactSummary: false)
                        }
                    } else {
                        queueColumn(showsCompactSummary: true)
                    }
                }
            }
        }
        .confirmationDialog(
            cancelAllTitle,
            isPresented: $confirmingCancelAll,
            titleVisibility: .visible
        ) {
            Button(cancelAllButtonTitle, role: .destructive) {
                model.queue.cancelAll()
            }
            .disabled(model.queue.cancellableCount == 0)
            Button("Keep downloads", role: .cancel) {}
        } message: {
            Text("Queued, downloading, finalizing, and paused downloads will be marked Cancelled. Partial progress may be lost. Finished files won’t be deleted.")
        }
        .alert(
            "Couldn’t retry failed downloads",
            isPresented: Binding(
                get: { bulkRetryError != nil },
                set: { if !$0 { bulkRetryError = nil } }
            )
        ) {
            Button("OK") { bulkRetryError = nil }
        } message: {
            Text(bulkRetryError ?? "Unknown error")
        }
    }

    private func queueColumn(showsCompactSummary: Bool) -> some View {
        VStack(spacing: 0) {
            if showsCompactSummary {
                compactSummaryBar
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            if showsQueueBar {
                queueActionsBar
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            queueHeader
            Rectangle().fill(Theme.border).frame(height: 1)
            if visibleItems.isEmpty, !selectedFilters.isEmpty {
                filteredEmptyState
            } else {
                List {
                    ForEach(visibleItems) { item in
                        QueueRow(item: item, model: model)
                            .moveDisabled(!selectedFilters.isEmpty || !model.queue.canReorder(item))
                            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    .onMove { source, destination in
                        guard selectedFilters.isEmpty else { return }
                        model.queue.move(fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var queueHeader: some View {
        HStack {
            Text("ITEM / STATUS / TRANSFER")
            Spacer()
            Text("ACTIONS")
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .tracking(0.8)
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Theme.canvas)
        .accessibilityHidden(true)
    }

    private var compactSummaryBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            filterHeader
            HStack(spacing: 8) {
                Text("QUEUE \(twoDigit(summary.totalCount))")
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 4)
                compactFilter("ACTIVE", value: summary.activeCount, color: Theme.accent, filter: .active)
                compactFilter("PAUSED", value: summary.pausedCount, color: Theme.warning, filter: .paused)
                compactFilter("DONE", value: summary.completedCount, color: Theme.success, filter: .complete)
                compactFilter("FAILED", value: summary.failedCount, color: Theme.danger, filter: .failed)
            }
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .tracking(0.5)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Theme.surface)
    }

    private func compactFilter(
        _ label: String,
        value: Int,
        color: Color,
        filter: QueueFilter
    ) -> some View {
        let selected = selectedFilters.contains(filter)
        return Button { toggle(filter) } label: {
            HStack(spacing: 4) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle.fill")
                    .font(.system(size: selected ? 8 : 5, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 8)
                Text("\(label) \(twoDigit(value))")
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.muted)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(selected ? color.opacity(0.16) : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(selected ? color.opacity(0.85) : Theme.border)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label.capitalized): \(value)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint("Toggle this queue filter")
    }

    private var summaryRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TRANSFER STATE")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Theme.muted)

            Text(twoDigit(summary.totalCount))
                .font(.system(size: 48, weight: .light, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 18)

            Text(summary.totalCount == 1 ? "job total" : "jobs total")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.muted)
                .padding(.top, 2)

            filterHeader
                .padding(.top, 24)

            VStack(spacing: 0) {
                railFilter("ACTIVE", value: summary.activeCount, color: Theme.accent, filter: .active)
                railFilter("PAUSED", value: summary.pausedCount, color: Theme.warning, filter: .paused)
                railFilter("COMPLETE", value: summary.completedCount, color: Theme.success, filter: .complete)
                railFilter("FAILED", value: summary.failedCount, color: Theme.danger, filter: .failed)
            }
            .padding(.top, 7)

            Spacer(minLength: 18)

            Text("OUTPUT")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Theme.muted)
            Text(outputLabel)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.accent)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.top, 7)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas)
    }

    private func railFilter(
        _ label: String,
        value: Int,
        color: Color,
        filter: QueueFilter
    ) -> some View {
        let selected = selectedFilters.contains(filter)
        return Button { toggle(filter) } label: {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle.fill")
                        .font(.system(size: selected ? 9 : 5, weight: .bold))
                        .foregroundStyle(color)
                        .frame(width: 9)
                    Text(label)
                }
                Spacer()
                Text(twoDigit(value))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.muted)
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(selected ? color : Theme.muted)
            .padding(.horizontal, 7)
            .padding(.vertical, 9)
            .background(selected ? color.opacity(0.14) : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(selected ? color.opacity(0.85) : Theme.border)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label.capitalized): \(value)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint("Toggle this queue filter")
    }

    private var filterHeader: some View {
        HStack {
            Text("FILTERS")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Theme.muted)
            Spacer()
            if !selectedFilters.isEmpty {
                Button("RESET") { selectedFilters.removeAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("Clear queue filters")
            }
        }
    }

    private var summary: QueueActivitySummary {
        QueueActivitySummary(items: model.queue.items)
    }

    private var visibleItems: [DownloadItem] {
        filteredQueueItems(model.queue.items, filters: selectedFilters)
    }

    private var outputLabel: String {
        let path = model.destination.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private func twoDigit(_ value: Int) -> String {
        String(format: "%02d", value)
    }

    private var showsQueueBar: Bool {
        model.hasVisibleQueueActions
    }

    private var queueActionsBar: some View {
        VStack(spacing: 8) {
            if model.queue.cancellableCount > 0 {
                HStack(spacing: 14) {
                    Button {
                        model.queue.pauseAllActive()
                    } label: {
                        Label("Pause all", systemImage: "pause.circle.fill")
                    }
                    .disabled(model.queue.pausableCount == 0)
                    .opacity(model.queue.pausableCount == 0 ? 0.45 : 1)
                    .help(batchHelp("Pause", count: model.queue.pausableCount))
                    .accessibilityLabel("Pause all downloads")
                    .accessibilityHint(batchHelp("Pause", count: model.queue.pausableCount))

                    Button {
                        model.queue.resumeAllPaused()
                    } label: {
                        Label("Resume all", systemImage: "play.circle.fill")
                    }
                    .disabled(model.queue.resumableCount == 0)
                    .opacity(model.queue.resumableCount == 0 ? 0.45 : 1)
                    .help(batchHelp("Resume", count: model.queue.resumableCount))
                    .accessibilityLabel("Resume all downloads")
                    .accessibilityHint(batchHelp("Resume", count: model.queue.resumableCount))

                    Button {
                        confirmingCancelAll = true
                    } label: {
                        Label("Cancel all…", systemImage: "xmark.circle.fill")
                    }
                    .foregroundStyle(Theme.danger)
                    .help(batchHelp("Cancel", count: model.queue.cancellableCount))
                    .accessibilityLabel("Cancel all downloads")
                    .accessibilityHint(batchHelp("Cancel", count: model.queue.cancellableCount))

                    Spacer()
                }
            }

            if model.retryableFailedCount > 0 || model.queue.hasSettledItems {
                HStack(spacing: 8) {
                    Spacer()
                    if model.retryableFailedCount > 0 {
                        retryAllButton(channel: .stable)
                        retryAllButton(channel: .nightly)
                    }
                    if model.queue.hasSettledItems {
                        Button {
                            model.queue.clearSettled()
                        } label: {
                            Label("Clear finished", systemImage: "trash")
                        }
                        .buttonStyle(QueueBatchActionButtonStyle(color: Theme.warning))
                        .disabled(retryingAllChannel != nil)
                        .help("Remove finished, failed and cancelled downloads from the list; downloaded files are kept")
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Theme.surface)
    }

    private func retryAllButton(channel: YtdlpEngineChannel) -> some View {
        let isWorking = retryingAllChannel == channel
        let color = channel == .stable ? Theme.accent : Theme.nightly
        let symbol = channel == .stable ? "arrow.clockwise" : "sparkles"
        return Button {
            retryAllFailed(using: channel)
        } label: {
            HStack(spacing: 6) {
                if isWorking {
                    ProgressView().controlSize(.small).tint(color)
                } else {
                    Image(systemName: symbol)
                }
                Text("Retry failed · \(channel.displayName)")
            }
        }
        .buttonStyle(QueueBatchActionButtonStyle(color: color))
        .disabled(retryingAllChannel != nil)
        .help("Retry \(model.retryableFailedCount) failed yt-dlp operation\(model.retryableFailedCount == 1 ? "" : "s") with \(channel.displayName)")
    }

    private func retryAllFailed(using channel: YtdlpEngineChannel) {
        guard retryingAllChannel == nil else { return }
        retryingAllChannel = channel
        Task { @MainActor in
            defer { retryingAllChannel = nil }
            do {
                try await model.retryAllFailed(using: channel)
            } catch {
                bulkRetryError = error.localizedDescription
            }
        }
    }

    private func toggle(_ filter: QueueFilter) {
        if selectedFilters.contains(filter) {
            selectedFilters.remove(filter)
        } else {
            selectedFilters.insert(filter)
        }
    }

    private var cancelAllTitle: String {
        let count = model.queue.cancellableCount
        return count == 1 ? "Cancel 1 download?" : "Cancel \(count) downloads?"
    }

    private var cancelAllButtonTitle: String {
        model.queue.cancellableCount == 1 ? "Cancel download" : "Cancel downloads"
    }

    private func batchHelp(_ action: String, count: Int) -> String {
        guard count > 0 else { return "No downloads to \(action.lowercased())" }
        return "\(action) \(count) download\(count == 1 ? "" : "s")"
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            BendingMark()
            VStack(spacing: 6) {
                Text("QUEUE_EMPTY")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(Theme.accent)
                Text("Nothing here yet")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Paste a video link to download it.")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Theme.muted)
            Text("No items match these filters")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
            Button("Reset filters") { selectedFilters.removeAll() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct QueueBatchActionButtonStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(color.opacity(configuration.isPressed ? 0.22 : 0.11))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(color.opacity(configuration.isPressed ? 1 : 0.7))
            }
            .opacity(isEnabled ? 1 : 0.38)
    }
}

private struct BendingMark: View {
    var body: some View {
        AnimatedBendingMark()
    }
}

/// The original empty-state animation and all of its original visual constants.
private struct AnimatedBendingMark: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            // Soft halo pooled under the icon.
            Circle()
                .fill(Theme.avatarGlow.opacity(0.16))
                .frame(width: 190, height: 190)
                .blur(radius: 40)

            // Emanating currents: blurred, low-opacity rings that expand and fade.
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .strokeBorder(Theme.avatarGlow.opacity(0.28), lineWidth: 2)
                    .frame(width: 150, height: 150)
                    .blur(radius: 2.5)
                    .scaleEffect(animate ? 2.1 : 0.8)
                    .opacity(animate ? 0 : 0.5)
                    .animation(
                        .easeOut(duration: 4.4).repeatForever(autoreverses: false).delay(Double(i) * 1.1),
                        value: animate
                    )
            }
            iconOrb
                .frame(width: 146, height: 146)
                .shadow(color: Theme.avatarGlow.opacity(0.4), radius: 24)
                .offset(y: animate ? -5 : 5)
                .animation(
                    .easeInOut(duration: 3.2).repeatForever(autoreverses: true),
                    value: animate
                )
        }
        .frame(height: 210)
        .onAppear { animate = true }
    }

    /// Falls back to a drawn orb when the bundled PNG is missing (e.g. plain `swift run`).
    @ViewBuilder private var iconOrb: some View {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            Image(nsImage: img).resizable()
        } else {
            ZStack {
                Circle().fill(RadialGradient(
                    colors: [Color(hex: 0x18446F), Color(hex: 0x060E1A)],
                    center: .init(x: 0.4, y: 0.35), startRadius: 4, endRadius: 70))
                Image(systemName: "arrow.down")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Theme.avatarWave)
            }
        }
    }
}
