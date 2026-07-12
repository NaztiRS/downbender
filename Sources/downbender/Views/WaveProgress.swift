import SwiftUI

/// Progress as flowing water: determinate flow, indeterminate sweep (`fraction == nil`), pulsing glow while merging.
struct WaveProgress: View {
    var fraction: Double?
    var pulsing: Bool = false
    var dimmed: Bool = false
    var height: CGFloat = 7

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false
    @State private var pulse = false

    private var baseGlow: Double { scheme == .dark ? 0.85 : 0.40 }
    private var glowRadius: CGFloat { scheme == .dark ? 7 : 3 }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)

                if let fraction {
                    let clamped = max(0, min(1, fraction))
                    let fillW = clamped <= 0 ? 0 : max(height, w * clamped)
                    Capsule()
                        .fill(Theme.wave)
                        .frame(width: fillW)
                        .opacity(dimmed ? 0.5 : 1)
                        .shadow(color: Theme.glow.opacity(currentGlow), radius: currentRadius)
                        // Wider, softer bloom under the fill: water glowing from below.
                        .shadow(color: Theme.glow.opacity(currentGlow * 0.45), radius: currentRadius * 2.6, y: 1)
                        .overlay(alignment: .trailing) {
                            Circle()
                                .fill(Theme.glow)
                                .frame(width: height + 3, height: height + 3)
                                .shadow(color: Theme.glow.opacity(baseGlow), radius: glowRadius)
                                .opacity(showHead(clamped) ? 1 : 0)
                        }
                        .animation(.easeOut(duration: 0.35), value: clamped)
                } else {
                    let segW = w * 0.32
                    Capsule()
                        .fill(Theme.wave)
                        .frame(width: segW)
                        .shadow(color: Theme.glow.opacity(baseGlow), radius: glowRadius)
                        .offset(x: sweep ? max(0, w - segW) : 0)
                }
            }
        }
        .frame(height: height)
        .onAppear(perform: startMotion)
        .onChange(of: pulsing) { _, _ in startMotion() }
    }

    private var currentGlow: Double {
        guard pulsing else { return dimmed ? baseGlow * 0.4 : baseGlow }
        return pulse ? 0.95 : 0.25
    }

    private var currentRadius: CGFloat {
        pulsing && pulse ? glowRadius + 5 : glowRadius
    }

    private func showHead(_ clamped: Double) -> Bool {
        !dimmed && clamped > 0.02 && clamped < 0.999
    }

    private func startMotion() {
        guard !reduceMotion else { return }
        if fraction == nil, !sweep {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { sweep = true }
        }
        if pulsing {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        } else {
            pulse = false
        }
    }
}
