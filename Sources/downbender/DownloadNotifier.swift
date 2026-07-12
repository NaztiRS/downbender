import AppKit
import DownbenderCore

/// Bounces the Dock icon and plays a sound: UserNotifications banners are impossible
/// for an ad-hoc-signed app (macOS denies authorization outright), so this is the
/// richest alert available without a paid Apple signing identity.
final class DownloadNotifier: CompletionNotifying {
    @MainActor func downloadFinished(title: String, success: Bool, filePath: String?) {
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)
        NSSound(named: success ? "Glass" : "Basso")?.play()
    }
}
