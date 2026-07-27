import AppKit
import SwiftUI

private struct ContinuousVisualEffectsAllowedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether this window should spend resources on decorative or repeating motion.
    var continuousVisualEffectsAllowed: Bool {
        get { self[ContinuousVisualEffectsAllowedKey.self] }
        set { self[ContinuousVisualEffectsAllowedKey.self] = newValue }
    }
}

/// Reports whether the AppKit window can currently put pixels on screen. SwiftUI's
/// scene phase alone does not distinguish a visible window from one that is minimized
/// or completely occluded.
struct WindowRenderStateReader: NSViewRepresentable {
    @Binding var isRenderable: Bool

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onRenderabilityChange = { isRenderable = $0 }
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onRenderabilityChange = { isRenderable = $0 }
    }

    final class ObserverView: NSView {
        var onRenderabilityChange: ((Bool) -> Void)?
        private var lastReportedValue: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installObservers()
            reportRenderability()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func observedStateDidChange(_ notification: Notification) {
            reportRenderability()
        }

        private func installObservers() {
            let center = NotificationCenter.default
            center.removeObserver(self)

            let windowNotifications: [Notification.Name] = [
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.didChangeOcclusionStateNotification,
            ]
            for name in windowNotifications {
                center.addObserver(
                    self,
                    selector: #selector(observedStateDidChange(_:)),
                    name: name,
                    object: window
                )
            }

            center.addObserver(
                self,
                selector: #selector(observedStateDidChange(_:)),
                name: NSApplication.didHideNotification,
                object: nil
            )
            center.addObserver(
                self,
                selector: #selector(observedStateDidChange(_:)),
                name: NSApplication.didUnhideNotification,
                object: nil
            )
        }

        private func reportRenderability() {
            let renderable = if let window {
                window.isVisible
                    && !window.isMiniaturized
                    && window.occlusionState.contains(.visible)
                    && !NSApplication.shared.isHidden
            } else {
                false
            }

            guard renderable != lastReportedValue else { return }
            lastReportedValue = renderable
            onRenderabilityChange?(renderable)
        }
    }
}
