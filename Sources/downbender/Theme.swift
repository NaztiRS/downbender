import SwiftUI

/// Downbender's visual identity tokens; adapt to macOS light/dark.
enum Theme {
    static let accent = Color.adaptive(light: 0x1478D8, dark: 0x3AA0F7)
    static let glow = Color.adaptive(light: 0x1FA2E0, dark: 0x6FD6FF)

    static let wave = LinearGradient(colors: [accent, glow], startPoint: .leading, endPoint: .trailing)

    static let track = Color.adaptive(lightColor: .black.opacity(0.08), darkColor: .white.opacity(0.12))
    static let hairline = Color.adaptive(lightColor: .black.opacity(0.08), darkColor: .white.opacity(0.10))
    static let surface = Color.adaptive(lightColor: .white.opacity(0.60), darkColor: .white.opacity(0.05))

    static let wash = LinearGradient(
        colors: [
            Color.adaptive(light: 0xEDF5FD, dark: 0x0B1E38),
            Color.adaptive(light: 0xFBFDFE, dark: 0x07111F),
        ],
        startPoint: .top, endPoint: .bottom
    )

    /// Card surface with depth: lit from above, like the icon's orb.
    static let surfaceDepth = LinearGradient(
        colors: [
            Color.adaptive(lightColor: .white.opacity(0.72), darkColor: .white.opacity(0.085)),
            Color.adaptive(lightColor: .white.opacity(0.52), darkColor: .white.opacity(0.03)),
        ],
        startPoint: .top, endPoint: .bottom
    )

    /// Glass rim for cards: bright top edge fading down.
    static let rim = LinearGradient(
        colors: [
            Color.adaptive(lightColor: .white.opacity(0.9), darkColor: .white.opacity(0.22)),
            Color.adaptive(lightColor: .black.opacity(0.06), darkColor: .white.opacity(0.04)),
        ],
        startPoint: .top, endPoint: .bottom
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
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(Theme.wave)
                    // Glossy top light, like the icon's orb.
                    .overlay(
                        Capsule()
                            .fill(LinearGradient(
                                colors: [.white.opacity(0.32), .white.opacity(0)],
                                startPoint: .top, endPoint: .center))
                            .padding(1)
                    )
            )
            .shadow(color: Theme.glow.opacity(isEnabled ? (scheme == .dark ? 0.55 : 0.30) : 0),
                    radius: 8, y: 2)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
