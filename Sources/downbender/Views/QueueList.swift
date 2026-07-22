import SwiftUI
import DownbenderCore

struct QueueList: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.queue.items.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                if model.queue.hasSettledItems { clearBar }
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.queue.items) { item in
                            QueueRow(item: item, model: model)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private var clearBar: some View {
        HStack {
            Spacer()
            Button("Clear finished") { model.queue.clearSettled() }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(Theme.accent)
                .help("Remove finished, failed and cancelled downloads from the list")
        }
        .padding(.horizontal, 16).padding(.top, 10)
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
