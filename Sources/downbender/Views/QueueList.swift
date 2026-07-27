import SwiftUI
import DownbenderCore

struct QueueList: View {
    @Bindable var model: AppModel
    @State private var confirmingCancelAll = false

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
            List {
                ForEach(model.queue.items) { item in
                    QueueRow(item: item, model: model)
                        .moveDisabled(!model.queue.canReorder(item))
                        .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onMove { source, destination in
                    model.queue.move(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
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
        HStack(spacing: 16) {
            Text("QUEUE")
                .foregroundStyle(Theme.textPrimary)
            Text(twoDigit(summary.totalCount))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 4)
            compactMetric("ACTIVE", value: summary.activeCount, color: Theme.accent)
            compactMetric("PAUSED", value: summary.pausedCount, color: Theme.warning)
            compactMetric("DONE", value: summary.completedCount, color: Theme.success)
            compactMetric("FAILED", value: summary.failedCount, color: Theme.danger)
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .tracking(0.5)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Theme.surface)
    }

    private func compactMetric(_ label: String, value: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(label) \(twoDigit(value))")
                .foregroundStyle(Theme.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label.capitalized): \(value)")
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

            VStack(spacing: 0) {
                railMetric("ACTIVE", value: summary.activeCount, color: Theme.accent)
                railMetric("PAUSED", value: summary.pausedCount, color: Theme.warning)
                railMetric("COMPLETE", value: summary.completedCount, color: Theme.success)
                railMetric("FAILED", value: summary.failedCount, color: Theme.danger)
            }
            .padding(.top, 26)

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

    private func railMetric(_ label: String, value: Int, color: Color) -> some View {
        HStack {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(label)
            }
            Spacer()
            Text(twoDigit(value))
                .foregroundStyle(Theme.textPrimary)
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(Theme.muted)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label.capitalized): \(value)")
    }

    private var summary: QueueActivitySummary {
        QueueActivitySummary(items: model.queue.items)
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
        model.queue.cancellableCount > 0 || model.queue.hasSettledItems
    }

    private var queueActionsBar: some View {
        HStack(spacing: 14) {
            if model.queue.cancellableCount > 0 {
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
            }

            Spacer()

            if model.queue.hasSettledItems {
                Button("Clear finished") { model.queue.clearSettled() }
                    .foregroundStyle(Theme.accent)
                    .help("Remove finished, failed and cancelled downloads from the list")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Theme.surface)
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
}

private struct BendingMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.continuousVisualEffectsAllowed) private var continuousVisualEffectsAllowed

    var body: some View {
        if continuousVisualEffectsAllowed && !reduceMotion {
            // This subtree is the original animation, unchanged. Removing it from the
            // hierarchy tears down every repeatForever when the window cannot render.
            AnimatedBendingMark()
        } else {
            StaticBendingMark()
        }
    }
}

/// The original empty-state animation and all of its original visual constants.
private struct AnimatedBendingMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        reduceMotion ? nil :
                            .easeOut(duration: 4.4).repeatForever(autoreverses: false).delay(Double(i) * 1.1),
                        value: animate
                    )
            }
            iconOrb
                .frame(width: 146, height: 146)
                .shadow(color: Theme.avatarGlow.opacity(0.4), radius: 24)
                .offset(y: animate ? -5 : 5)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 3.2).repeatForever(autoreverses: true),
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

/// Matches the original reduced-motion resting state without installing any animation.
private struct StaticBendingMark: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.avatarGlow.opacity(0.16))
                .frame(width: 190, height: 190)
                .blur(radius: 40)

            iconOrb
                .frame(width: 146, height: 146)
                .shadow(color: Theme.avatarGlow.opacity(0.4), radius: 24)
                .offset(y: -5)
        }
        .frame(height: 210)
    }

    /// Same fallback as the animated mark.
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
