import SwiftUI

/// Flat progress treatment. Indeterminate and finalizing motion remains visibility-aware.
struct WaveProgress: View {
    var fraction: Double?
    var pulsing: Bool = false
    var dimmed: Bool = false
    var updatesFrequently: Bool = false
    var height: CGFloat = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.continuousVisualEffectsAllowed) private var continuousVisualEffectsAllowed
    @State private var sweep = false
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: max(1, height / 2), style: .continuous)
                    .fill(Theme.track)

                if let fraction {
                    let clamped = max(0, min(1, fraction))
                    ProgressCapsule(progress: clamped)
                        .fill(Theme.accent)
                        .opacity(fillOpacity)
                        .animation(progressAnimation, value: clamped)
                        .animation(pulseAnimation, value: pulse)
                } else {
                    let segmentWidth = max(height, width * 0.28)
                    RoundedRectangle(cornerRadius: max(1, height / 2), style: .continuous)
                        .fill(Theme.accent)
                        .frame(width: segmentWidth)
                        .opacity(dimmed ? 0.38 : 1)
                        .offset(x: sweep ? max(0, width - segmentWidth) : 0)
                        .animation(sweepAnimation, value: sweep)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Download progress")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(accessibilityTraits)
        .task(id: motionConfiguration) {
            resetMotion()
            guard motionConfiguration.hasMotion else { return }

            await Task.yield()
            guard !Task.isCancelled else { return }
            sweep = motionConfiguration.sweeps
            pulse = motionConfiguration.pulses
        }
    }

    private var motionEnabled: Bool {
        continuousVisualEffectsAllowed && !reduceMotion && !dimmed
    }

    private var motionConfiguration: MotionConfiguration {
        MotionConfiguration(
            sweeps: motionEnabled && fraction == nil,
            pulses: motionEnabled && pulsing
        )
    }

    private var progressAnimation: Animation? {
        motionEnabled ? .easeOut(duration: 0.24) : nil
    }

    private var sweepAnimation: Animation? {
        guard motionConfiguration.sweeps else { return nil }
        return .easeInOut(duration: 1.15).repeatForever(autoreverses: true)
    }

    private var pulseAnimation: Animation? {
        guard motionConfiguration.pulses else { return nil }
        return .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
    }

    private func resetMotion() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            sweep = false
            pulse = false
        }
    }

    private var fillOpacity: Double {
        if dimmed { return 0.38 }
        guard pulsing, motionEnabled else { return 1 }
        return pulse ? 1 : 0.52
    }

    private var accessibilityValue: String {
        if dimmed {
            guard let fraction else { return "Paused" }
            return "Paused, \(percentage(for: fraction)) percent"
        }
        if pulsing {
            return "Finalizing"
        }
        guard let fraction else {
            return "In progress, percentage unavailable"
        }

        let clamped = max(0, min(1, fraction))
        return clamped == 1 ? "Complete" : "\(percentage(for: clamped)) percent"
    }

    private var accessibilityTraits: AccessibilityTraits {
        guard updatesFrequently, !dimmed, !pulsing else { return [] }
        if let fraction, max(0, min(1, fraction)) == 1 { return [] }
        return .updatesFrequently
    }

    private func percentage(for fraction: Double) -> Int {
        Int((max(0, min(1, fraction)) * 100).rounded())
    }

}

private struct MotionConfiguration: Hashable {
    let sweeps: Bool
    let pulses: Bool

    var hasMotion: Bool {
        sweeps || pulses
    }
}

/// Draws the changing fill inside fixed layout bounds. Animating the shape updates
/// only its path instead of relaying out the row for every progress sample.
private struct ProgressCapsule: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clamped = max(0, min(1, progress))
        guard clamped > 0, rect.width > 0, rect.height > 0 else { return Path() }

        let width = min(rect.width, max(rect.height, rect.width * clamped))
        let fillRect = CGRect(origin: rect.origin, size: CGSize(width: width, height: rect.height))
        return RoundedRectangle(cornerRadius: rect.height / 2, style: .continuous).path(in: fillRect)
    }
}
