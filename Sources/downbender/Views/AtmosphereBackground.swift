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

/// The main window backdrop stays calm; decorative moving streaks are intentionally
/// omitted so the empty-state avatar is the only ambient animation.
struct AtmosphereBackground: View {
    var body: some View {
        WashBackground()
            .ignoresSafeArea()
    }
}
