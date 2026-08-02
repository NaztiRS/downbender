import AppKit
import Observation
import SwiftUI
import UserNotifications
import DownbenderCore

struct CompletionNotice: Identifiable, Equatable {
    let id: UUID
    let title: String
    let success: Bool
    let fileURL: URL?

    var heading: String { success ? "Download complete" : "Download failed" }
    var symbol: String { success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill" }
    var actionTitle: String { fileURL == nil ? "Open Downbender" : "Show in Finder" }
}

/// Completion feedback that works in both foreground and background:
/// an in-app banner is always queued, while background completions also request a
/// clickable system notification (with Dock attention as the no-permission fallback).
@MainActor @Observable
final class DownloadNotifier: CompletionNotifying {
    private(set) var notices: [CompletionNotice] = []
    var currentNotice: CompletionNotice? { notices.first }

    @ObservationIgnored private let notificationCenter = UNUserNotificationCenter.current()
    @ObservationIgnored private let responseDelegate = CompletionNotificationDelegate()
    @ObservationIgnored private var openApp: (() -> Void)?

    func configure(openApp: @escaping () -> Void) {
        self.openApp = openApp
        responseDelegate.onOpen = { [weak self] filePath, noticeID in
            Task { @MainActor in self?.open(filePath: filePath, noticeID: noticeID) }
        }
        notificationCenter.delegate = responseDelegate
        notificationCenter.setNotificationCategories([
            UNNotificationCategory(
                identifier: NotificationCategory.revealFile,
                actions: [
                    UNNotificationAction(
                        identifier: NotificationAction.showFile,
                        title: "Show in Finder"
                    ),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: NotificationCategory.openApp,
                actions: [
                    UNNotificationAction(
                        identifier: NotificationAction.openApp,
                        title: "Open Downbender"
                    ),
                ],
                intentIdentifiers: []
            ),
        ])
    }

    func downloadFinished(title: String, success: Bool, filePath: String?) {
        let notice = CompletionNotice(
            id: UUID(),
            title: title,
            success: success,
            fileURL: filePath.map { URL(fileURLWithPath: $0) }
        )
        notices.insert(notice, at: 0)
        if notices.count > 5 {
            let discardedIdentifiers = notices.dropFirst(5).map { $0.id.uuidString }
            notices.removeLast(notices.count - 5)
            removeSystemNotifications(withIdentifiers: discardedIdentifiers)
        }

        if NSApp.isActive {
            NSSound(named: success ? "Glass" : "Basso")?.play()
        } else {
            NSApp.requestUserAttention(.informationalRequest)
            deliverSystemNotification(for: notice)
        }
    }

    func dismiss(_ notice: CompletionNotice) {
        notices.removeAll { $0.id == notice.id }
        removeSystemNotifications(withIdentifiers: [notice.id.uuidString])
    }

    /// The banner shows only the first queued notice. Closing it should close the visible
    /// notification stack instead of immediately replacing it with an older, similar banner.
    func dismissAll() {
        let identifiers = notices.map { $0.id.uuidString }
        notices.removeAll()
        removeSystemNotifications(withIdentifiers: identifiers)
    }

    func performPrimaryAction(for notice: CompletionNotice) {
        dismiss(notice)
        if let fileURL = notice.fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            openApp?()
        }
    }

    private func deliverSystemNotification(for notice: CompletionNotice) {
        Task {
            guard await notificationsAreAuthorized() else {
                NSSound(named: notice.success ? "Glass" : "Basso")?.play()
                return
            }
            // The user may have dismissed the in-app banner while authorization was pending.
            guard notices.contains(where: { $0.id == notice.id }) else { return }

            let content = UNMutableNotificationContent()
            content.title = notice.heading
            content.body = notice.title
            content.sound = .default
            content.categoryIdentifier = notice.fileURL == nil
                ? NotificationCategory.openApp
                : NotificationCategory.revealFile
            content.userInfo[NotificationUserInfo.noticeID] = notice.id.uuidString
            if let path = notice.fileURL?.path {
                content.userInfo[NotificationUserInfo.filePath] = path
            }

            do {
                try await notificationCenter.add(
                    UNNotificationRequest(
                        identifier: notice.id.uuidString,
                        content: content,
                        trigger: nil
                    )
                )
                // `add` is async too. If dismissal raced it, remove the request that just landed.
                if !notices.contains(where: { $0.id == notice.id }) {
                    removeSystemNotifications(withIdentifiers: [notice.id.uuidString])
                }
            } catch {
                NSSound(named: notice.success ? "Glass" : "Basso")?.play()
            }
        }
    }

    private func notificationsAreAuthorized() async -> Bool {
        let settings = await notificationCenter.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            do {
                return try await notificationCenter.requestAuthorization(options: [.alert, .sound])
            } catch {
                return false
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func removeSystemNotifications(withIdentifiers identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func open(filePath: String?, noticeID: UUID?) {
        if let noticeID {
            notices.removeAll { $0.id == noticeID }
        }
        if let filePath, FileManager.default.fileExists(atPath: filePath) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
        } else {
            openApp?()
        }
    }
}

private enum NotificationCategory {
    static let revealFile = "DOWNBENDER_REVEAL_DOWNLOAD"
    static let openApp = "DOWNBENDER_OPEN_APP"
}

private enum NotificationAction {
    static let showFile = "DOWNBENDER_SHOW_FILE"
    static let openApp = "DOWNBENDER_OPEN_APP"
}

private enum NotificationUserInfo {
    static let filePath = "filePath"
    static let noticeID = "noticeID"
}

private final class CompletionNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: (@Sendable (String?, UUID?) -> Void)?

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let filePath = userInfo[NotificationUserInfo.filePath] as? String
        let noticeID = (userInfo[NotificationUserInfo.noticeID] as? String).flatMap(UUID.init(uuidString:))
        onOpen?(filePath, noticeID)
    }
}

@MainActor
func bringMainWindowForward() {
    NSApp.activate(ignoringOtherApps: true)
    if let window = NSApp.windows.first(where: { $0.title == "Downbender" }) {
        window.makeKeyAndOrderFront(nil)
    }
}

struct CompletionBannerHost: View {
    @Bindable var notifier: DownloadNotifier

    var body: some View {
        if let notice = notifier.currentNotice {
            HStack(spacing: 10) {
                Image(systemName: notice.symbol)
                    .foregroundStyle(notice.success ? .green : .orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.heading).font(.callout.weight(.semibold))
                    Text(notice.title).font(.caption).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(notice.actionTitle) {
                    notifier.performPrimaryAction(for: notice)
                }
                .buttonStyle(.bordered)
                Button {
                    notifier.dismissAll()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss notification")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
            .padding(12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
        }
    }
}
