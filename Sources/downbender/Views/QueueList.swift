import SwiftUI
import DownbenderCore

struct QueueList: View {
    @Bindable var model: AppModel
    @State private var confirmingCancelAll = false

    var body: some View {
        if model.queue.items.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                if showsQueueBar {
                    queueActionsBar
                    Divider()
                }
                List {
                    ForEach(model.queue.items) { item in
                        QueueRow(item: item, model: model)
                            .moveDisabled(!model.queue.canReorder(item))
                            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
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
                .foregroundStyle(.red)
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
        .font(.callout)
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            VStack(spacing: 4) {
                Text("Nothing here yet").font(.title3.weight(.semibold))
                Text("Paste a video link to download it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BendingMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        ZStack {
            // Soft halo pooled under the icon.
            Circle()
                .fill(Theme.glow.opacity(0.16))
                .frame(width: 190, height: 190)
                .blur(radius: 40)

            // Emanating currents: blurred, low-opacity rings that expand and fade.
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .strokeBorder(Theme.glow.opacity(0.28), lineWidth: 2)
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
                .shadow(color: Theme.glow.opacity(0.4), radius: 24)
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
                    .foregroundStyle(Theme.wave)
            }
        }
    }
}
