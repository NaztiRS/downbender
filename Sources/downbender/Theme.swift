import SwiftUI

/// Command Mono: a compact, flat interface inspired by developer tools.
enum Theme {
    static let canvas = Color(hex: 0x080808)
    static let surface = Color(hex: 0x111111)
    static let raised = Color(hex: 0x171717)
    static let border = Color(hex: 0x292929)
    static let borderStrong = Color(hex: 0x454545)
    static let textPrimary = Color(hex: 0xF4F4F4)
    static let muted = Color(hex: 0x898989)
    static let accent = Color(hex: 0x66D9FF)
    static let success = Color(hex: 0x67D391)
    static let warning = Color(hex: 0xF1BA62)
    static let danger = Color(hex: 0xFF6B6B)

    static let track = border
    static let hairline = border
    static let wash = canvas

    /// These retain the exact pre-refactor empty-state avatar colors.
    static let avatarGlow = Color.adaptive(light: 0x1FA2E0, dark: 0x6FD6FF)
    static let avatarAccent = Color.adaptive(light: 0x1478D8, dark: 0x3AA0F7)
    static let avatarWave = LinearGradient(
        colors: [avatarAccent, avatarGlow],
        startPoint: .leading,
        endPoint: .trailing
    )
}

extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }

    /// Dynamic color that resolves by system appearance (aqua / darkAqua).
    static func adaptive(lightColor: Color, darkColor: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(darkColor) : NSColor(lightColor)
        })
    }

    static func adaptive(light: UInt, dark: UInt) -> Color {
        adaptive(lightColor: Color(hex: light), darkColor: Color(hex: dark))
    }
}

struct WaveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .textCase(.uppercase)
            .foregroundStyle(Theme.canvas)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.accent)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.textPrimary.opacity(isEnabled ? 0.28 : 0.08))
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
