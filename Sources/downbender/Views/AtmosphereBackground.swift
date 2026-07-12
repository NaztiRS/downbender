import SwiftUI

/// Deep-water wash plus a faint cyan light from above. The calm base backdrop,
/// used on its own where motion would distract (Settings).
struct WashBackground: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Theme.wash)
            RadialGradient(
                colors: [Theme.glow.opacity(0.14), .clear],
                center: UnitPoint(x: 0.5, y: -0.2),
                startRadius: 10, endRadius: 560
            )
        }
        .ignoresSafeArea()
    }
}

/// The main window backdrop: the wash plus a few thin horizontal data-streaks
/// drifting across — echoing the hero art. Streaks are GPU-composited and drop
/// under reduce-motion.
struct AtmosphereBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            WashBackground()
            if !reduceMotion { DataStreaks() }
        }
        .ignoresSafeArea()
    }
}

private struct DataStreaks: View {
    struct Streak {
        let y: CGFloat        // vertical band, 0…1
        let length: CGFloat
        let duration: Double
        let delay: Double
        let opacity: Double
    }

    // Sparse and staggered on purpose: atmosphere, not a screensaver.
    private let streaks: [Streak] = [
        .init(y: 0.14, length: 70,  duration: 8.0, delay: 0.0, opacity: 0.42),
        .init(y: 0.29, length: 46,  duration: 9.5, delay: 3.4, opacity: 0.26),
        .init(y: 0.44, length: 90,  duration: 6.8, delay: 1.7, opacity: 0.34),
        .init(y: 0.61, length: 40,  duration: 11.0, delay: 5.0, opacity: 0.22),
        .init(y: 0.76, length: 64,  duration: 8.6, delay: 2.5, opacity: 0.30),
        .init(y: 0.9,  length: 52,  duration: 10.0, delay: 6.2, opacity: 0.24),
    ]

    @State private var go = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(streaks.indices, id: \.self) { i in
                    let s = streaks[i]
                    streak(s)
                        .offset(
                            x: go ? geo.size.width + s.length : -s.length,
                            y: s.y * geo.size.height
                        )
                        .animation(
                            .linear(duration: s.duration).repeatForever(autoreverses: false).delay(s.delay),
                            value: go
                        )
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { go = true }
    }

    /// A thin straight trail with a brighter head — like a packet skimming past.
    private func streak(_ s: Streak) -> some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [.clear, Theme.glow.opacity(s.opacity)],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: s.length, height: 1)
            Circle()
                .fill(Theme.glow.opacity(min(1, s.opacity + 0.3)))
                .frame(width: 2.4, height: 2.4)
                .shadow(color: Theme.glow.opacity(s.opacity), radius: 3)
        }
        .blur(radius: 0.4)
    }
}
