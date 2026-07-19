import DownbenderCore
import Foundation

struct ChromeIntegrationState {
    let extensionDirectory: URL?
    let temporaryShortcut: URL?
    let isInstalled: Bool
    let errorMessage: String?

    var isInstalling: Bool { temporaryShortcut != nil && errorMessage == nil }
    var isAvailable: Bool { extensionDirectory != nil && errorMessage == nil }
}

enum ChromeIntegrationInstaller {
    private static let extensionFolderName = "ChromeExtension"
    private static let temporaryShortcutName = "Downbender Extension Installer"
    private static let installedKey = "chromeIntegrationInstalled"
    private static let legacyVisibleFolderName = "Downbender Chrome Extension"

    static func status() -> ChromeIntegrationState {
        do {
            let extensionDirectory = try bundledExtensionDirectory()
            let shortcut = temporaryShortcutURL()
            let shortcutExists = FileManager.default.fileExists(atPath: shortcut.path)
            return ChromeIntegrationState(
                extensionDirectory: extensionDirectory,
                temporaryShortcut: shortcutExists ? shortcut : nil,
                isInstalled: integrationWasInstalled(),
                errorMessage: nil
            )
        } catch {
            return ChromeIntegrationState(
                extensionDirectory: nil,
                temporaryShortcut: nil,
                isInstalled: false,
                errorMessage: error.localizedDescription
            )
        }
    }

    /// Creates only a temporary, visible symlink. Chrome resolves it to the extension bundled
    /// inside Downbender, so the symlink can be removed after the user confirms installation.
    static func beginInstallation() -> ChromeIntegrationState {
        do {
            let fileManager = FileManager.default
            let extensionDirectory = try bundledExtensionDirectory()
            try installNativeHostManifest(fileManager: fileManager)

            let shortcut = temporaryShortcutURL()
            if fileManager.fileExists(atPath: shortcut.path) {
                guard shortcut.resolvingSymlinksInPath() == extensionDirectory.resolvingSymlinksInPath() else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try fileManager.removeItem(at: shortcut)
            }
            try fileManager.createSymbolicLink(at: shortcut, withDestinationURL: extensionDirectory)
            return ChromeIntegrationState(
                extensionDirectory: extensionDirectory,
                temporaryShortcut: shortcut,
                isInstalled: integrationWasInstalled(),
                errorMessage: nil
            )
        } catch {
            return ChromeIntegrationState(
                extensionDirectory: nil,
                temporaryShortcut: nil,
                isInstalled: integrationWasInstalled(),
                errorMessage: error.localizedDescription
            )
        }
    }

    /// Called only after the user confirms that Chrome loaded the temporary shortcut.
    static func finishInstallation(appSupportDirectory: URL) -> ChromeIntegrationState {
        do {
            let fileManager = FileManager.default
            let extensionDirectory = try bundledExtensionDirectory()
            try removeTemporaryShortcut(fileManager: fileManager, extensionDirectory: extensionDirectory)
            UserDefaults.standard.set(true, forKey: installedKey)
            cleanupLegacyCopies(appSupportDirectory: appSupportDirectory, fileManager: fileManager)
            return ChromeIntegrationState(
                extensionDirectory: extensionDirectory,
                temporaryShortcut: nil,
                isInstalled: true,
                errorMessage: nil
            )
        } catch {
            return ChromeIntegrationState(
                extensionDirectory: nil,
                temporaryShortcut: nil,
                isInstalled: integrationWasInstalled(),
                errorMessage: error.localizedDescription
            )
        }
    }

    static func cancelInstallation() -> ChromeIntegrationState {
        if let extensionDirectory = try? bundledExtensionDirectory() {
            _ = try? ChromeExtensionShortcut.removeIfOwned(
                at: temporaryShortcutURL(),
                expectedDestination: extensionDirectory
            )
        }
        return status()
    }

    /// Keeps the absolute native-host path current after an app update or move, without creating
    /// any visible installation files.
    static func refreshInstalledIntegration() {
        guard integrationWasInstalled() else { return }
        try? installNativeHostManifest(fileManager: .default)
    }

    private static func bundledExtensionDirectory() throws -> URL {
        guard let resources = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
        let extensionDirectory = resources.appendingPathComponent(extensionFolderName, isDirectory: true)
        guard FileManager.default.fileExists(
            atPath: extensionDirectory.appendingPathComponent("manifest.json").path
        ) else { throw CocoaError(.fileNoSuchFile) }
        return extensionDirectory
    }

    private static func temporaryShortcutURL() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(temporaryShortcutName, isDirectory: true)
    }

    private static func integrationWasInstalled() -> Bool {
        if UserDefaults.standard.bool(forKey: installedKey) { return true }
        // Migration from the first companion build, which registered the host on app launch.
        return FileManager.default.fileExists(atPath: nativeHostManifestURL().path)
    }

    private static func removeTemporaryShortcut(fileManager: FileManager, extensionDirectory: URL) throws {
        _ = try ChromeExtensionShortcut.removeIfOwned(
            at: temporaryShortcutURL(),
            expectedDestination: extensionDirectory,
            fileManager: fileManager
        )
    }

    private static func cleanupLegacyCopies(appSupportDirectory: URL, fileManager: FileManager) {
        let downloadsCopy = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(legacyVisibleFolderName, isDirectory: true)
        let supportCopy = appSupportDirectory.appendingPathComponent(extensionFolderName, isDirectory: true)
        for copy in [downloadsCopy, supportCopy] where isDownbenderExtension(at: copy) {
            try? fileManager.removeItem(at: copy)
        }
    }

    private static func isDownbenderExtension(at directory: URL) -> Bool {
        let manifest = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["key"] is String && object["name"] as? String == "Downbender Companion"
    }

    private static func nativeHostManifestURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Google/Chrome/NativeMessagingHosts/\(BrowserBridge.nativeHostName).json"
        )
    }

    private static func installNativeHostManifest(fileManager: FileManager) throws {
        guard let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() else {
            throw CocoaError(.fileNoSuchFile)
        }
        let hostExecutable = executableDirectory.appendingPathComponent("downbender-native-host")
        guard fileManager.isExecutableFile(atPath: hostExecutable.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let destination = nativeHostManifestURL()
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "name": BrowserBridge.nativeHostName,
            "description": "Send Chrome video links to Downbender",
            "path": hostExecutable.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(BrowserBridge.chromeExtensionID)/"],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destination, options: .atomic)
    }
}
