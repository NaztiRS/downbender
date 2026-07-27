import AppKit
import SwiftUI
import DownbenderCore

@MainActor
private final class DownbenderAppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    let notifier = DownloadNotifier()
    private weak var systemSurfaceQueue: SystemSurfaceQueueState?
    private var lastDockBadge: String?
    var openMainWindowHandler: (() -> Void)? {
        didSet {
            guard shouldOpenMainWindowWhenReady, openMainWindowHandler != nil else { return }
            shouldOpenMainWindowWhenReady = false
            presentMainWindow()
        }
    }
    private var shouldOpenMainWindowWhenReady = false

    func bind(model: AppModel, systemSurfaceQueue: SystemSurfaceQueueState) {
        self.model = model
        self.systemSurfaceQueue = systemSurfaceQueue
        systemSurfaceQueue.bind(to: model.queue) { [weak self] snapshot in
            self?.updateDockBadge(snapshot)
        }
    }

    func applicationWillFinishLaunching(_: Notification) {
        // Apple requires the notification delegate before launch finishes so a response
        // that launches the app is not lost.
        notifier.configure { [weak self] in self?.presentMainWindow() }
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        let active = TerminationPolicy.interruptedCount(model.queue.items)
        guard active > 0 else {
            model.saveQueueNow()
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = active == 1 ? "1 download in progress" : "\(active) downloads in progress"
        alert.informativeText = "Downloads will be paused — you can resume them next time you open Downbender."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task { @MainActor in
            // Pauses everything, waits (≤3 s) for child processes to be reaped, saves the queue.
            await model.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_: Notification) {
        ChromeIntegrationInstaller.cleanUpTemporaryInstaller()
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        presentMainWindow()
        return true
    }

    func applicationDockMenu(_: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        if let model {
            let summary = systemSurfaceQueue?.snapshot ?? QueueActivitySnapshot(items: model.queue.items)
            let status = NSMenuItem(title: dockStatusText(summary), action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            menu.addItem(.separator())

            if model.queue.cancellableCount > 0 {
                addDockItem(
                    to: menu,
                    title: "Pause All",
                    action: #selector(pauseAllFromSystemSurface),
                    enabled: model.queue.pausableCount > 0
                )
                addDockItem(
                    to: menu,
                    title: "Resume All",
                    action: #selector(resumeAllFromSystemSurface),
                    enabled: model.queue.resumableCount > 0
                )
                menu.addItem(.separator())
            }

            if let notice = notifier.currentNotice {
                addDockItem(
                    to: menu,
                    title: notice.actionTitle,
                    action: #selector(openLatestCompletion)
                )
            }
            addDockItem(
                to: menu,
                title: "Open Downloads Folder",
                action: #selector(openDownloadsFolder)
            )
        }
        addDockItem(to: menu, title: "Open Downbender", action: #selector(openMainWindowFromSystemSurface))
        return menu
    }

    private func updateDockBadge(_ summary: QueueActivitySnapshot) {
        let badge: String?
        if summary.activeCount > 0 {
            if let percent = summary.progressPercent {
                badge = "\(percent)%"
            } else {
                badge = "\(summary.activeCount)"
            }
        } else if summary.pausedCount > 0 {
            badge = "Ⅱ \(summary.pausedCount)"
        } else if summary.failedCount > 0 {
            badge = "!"
        } else if summary.analyzingCount > 0 {
            badge = "…"
        } else if summary.choosingCount > 0 {
            badge = "?"
        } else {
            badge = nil
        }
        guard badge != lastDockBadge else { return }
        lastDockBadge = badge
        NSApp.dockTile.badgeLabel = badge
    }

    private func dockStatusText(_ summary: QueueActivitySnapshot) -> String {
        if summary.activeCount > 0 {
            let noun = summary.activeCount == 1 ? "download" : "downloads"
            if let percent = summary.progressPercent {
                return "\(summary.activeCount) \(noun) · \(percent)%"
            }
            return "\(summary.activeCount) \(noun) active"
        }
        if summary.pausedCount > 0 {
            return "\(summary.pausedCount) paused"
        }
        if summary.failedCount > 0 {
            return "\(summary.failedCount) failed"
        }
        if summary.analyzingCount > 0 {
            return "\(summary.analyzingCount) analyzing"
        }
        if summary.choosingCount > 0 {
            return "\(summary.choosingCount) awaiting choice"
        }
        return "No active downloads"
    }

    private func addDockItem(
        to menu: NSMenu,
        title: String,
        action: Selector,
        enabled: Bool = true
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc private func pauseAllFromSystemSurface() {
        model?.queue.pauseAllActive()
    }

    @objc private func resumeAllFromSystemSurface() {
        model?.queue.resumeAllPaused()
    }

    @objc private func openDownloadsFolder() {
        guard let destination = model?.destination else { return }
        NSWorkspace.shared.open(destination)
    }

    @objc private func openMainWindowFromSystemSurface() {
        presentMainWindow()
    }

    @objc private func openLatestCompletion() {
        guard let notice = notifier.currentNotice else { return }
        notifier.performPrimaryAction(for: notice)
    }

    private func presentMainWindow() {
        guard let openMainWindowHandler else {
            shouldOpenMainWindowWhenReady = true
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        openMainWindowHandler()
        bringMainWindowForward()
    }
}

@main
struct DownbenderApp: App {
    @NSApplicationDelegateAdaptor(DownbenderAppDelegate.self) private var appDelegate
    @State private var model: AppModel?
    @State private var systemSurfaceQueue = SystemSurfaceQueueState()
    @State private var pendingExternalRequests: [BrowserDeepLinkRequest] = []

    init() {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        Window("Downbender", id: "main") {
            Group {
                if let model {
                    RootView(model: model)
                        .overlay(alignment: .top) {
                            CompletionBannerHost(notifier: appDelegate.notifier)
                        }
                } else {
                    Text("Embedded binaries not found.").padding()
                }
            }
            .onAppear { prepareModel() }
            .onOpenURL(perform: receiveExternalURL)
            .handlesExternalEvents(preferring: ["add"], allowing: ["add"])
            .background {
                MainWindowOpenBridge { handler in
                    appDelegate.openMainWindowHandler = handler
                }
            }
            .tint(Theme.accent)
            // Dark mode only, by design decision.
            .preferredColorScheme(.dark)
        }
        // 1,087 × 737 including the macOS title bar—the preferred visible frame.
        .defaultSize(width: 1_087, height: 680)
        .commands {
            CommandGroup(after: .pasteboard) {
                Button("Paste and Download") {
                    // The delegate holds the model (wired in prepareModel); commands closures
                    // don't observe @State reliably, the delegate reference is always current.
                    guard let model = appDelegate.model,
                          let text = NSPasteboard.general.string(forType: .string) else { return }
                    for url in URLBatch.split(text) { model.addURL(url) }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }
        }
        Settings {
            if let model {
                SettingsView(model: model)
                    .tint(Theme.accent)
                    .preferredColorScheme(.dark)
            }
        }
        MenuBarExtra {
            if let model {
                MenuBarQueueView(
                    model: model,
                    notifier: appDelegate.notifier,
                    systemSurfaceQueue: systemSurfaceQueue
                )
            } else {
                Text("Downbender is starting…")
                    .padding()
            }
        } label: {
            if model != nil {
                MenuBarQueueLabel(systemSurfaceQueue: systemSurfaceQueue)
            } else {
                Label("Downbender", systemImage: "arrow.down.circle")
            }
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor private func prepareModel() {
        if model == nil {
            model = makeModel()
            if let model {
                appDelegate.bind(model: model, systemSurfaceQueue: systemSurfaceQueue)
                // Restore BEFORE sweeping, so rehydrated paused items protect their .part files.
                model.restoreQueue()
                model.sweepTemporary()
            }
        }
        guard let model else { return }
        for request in pendingExternalRequests {
            enqueueExternalRequest(request, with: model)
        }
        pendingExternalRequests.removeAll()
    }

    @MainActor private func receiveExternalURL(_ deepLink: URL) {
        guard let request = BrowserBridge.deepLinkRequest(from: deepLink) else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let model {
            enqueueExternalRequest(request, with: model)
        } else {
            pendingExternalRequests.append(request)
        }
    }

    @MainActor private func enqueueExternalRequest(_ request: BrowserDeepLinkRequest, with model: AppModel) {
        guard model.addURL(request.webURL.absoluteString), let acknowledgementID = request.acknowledgementID else {
            return
        }
        try? BrowserEnqueueAcknowledgement.signal(
            acknowledgementID,
            appSupportDirectory: Self.appSupportDirectory()
        )
    }

    private static func appSupportDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downbender")
    }

    @MainActor private func makeModel() -> AppModel? {
        let fm = FileManager.default
        let support = Self.appSupportDirectory(fileManager: fm)
        ChromeIntegrationInstaller.prepareIntegration()
        guard let binaries = BundledBinaries.locate(appSupportDirectory: support) else { return nil }
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let tmp = fm.temporaryDirectory.appendingPathComponent("Downbender")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        return AppModel(
            binaries: binaries, destination: downloads, tmpDirectory: tmp,
            appSupportDirectory: support,
            cookiesBrowser: UserDefaults.standard.string(forKey: AppModel.cookiesBrowserKey),
            notifier: appDelegate.notifier
        )
    }
}

private struct MainWindowOpenBridge: View {
    @Environment(\.openWindow) private var openWindow
    let install: (@escaping () -> Void) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                install {
                    openWindow(id: "main")
                }
            }
            .accessibilityHidden(true)
    }
}
