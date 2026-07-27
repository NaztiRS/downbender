import SwiftUI

/// Static Command Mono canvas. It performs no continuous background work.
struct WashBackground: View {
    var body: some View {
        Rectangle()
            .fill(Theme.canvas)
            .ignoresSafeArea()
    }
}

/// The empty-state avatar remains the only ambient animation in the main window.
struct AtmosphereBackground: View {
    var body: some View {
        WashBackground()
            .ignoresSafeArea()
    }
}
