import DownbenderCore
import Foundation

struct ChromeIntegrationState {
    let extensionDirectory: URL?
    let temporaryShortcut: URL?
    let errorMessage: String?

    var isInstalling: Bool { temporaryShortcut != nil && errorMessage == nil }
    var isAvailable: Bool { extensionDirectory != nil && errorMessage == nil }
}

@MainActor
enum ChromeIntegrationInstaller {
    private static let extensionFolderName = "ChromeExtension"
    private static let temporaryShortcutName = "Downbender Extension Installer"
    private static let legacyVisibleFolderName = "Downbender Chrome Extension"
    private static let expirationKey = "chromeExtensionInstallerExpiration"
    private static let installerLifetime: TimeInterval = 60 * 60
    private static var expirationTask: Task<Void, Never>?

    static func status() -> ChromeIntegrationState {
        do {
            let extensionDirectory = try bundledExtensionDirectory()
            removeExpiredTemporaryShortcut()
            let shortcut = temporaryShortcutURL()
            let shortcutExists = isOwnedShortcut(shortcut, destination: extensionDirectory)
            if !shortcutExists {
                cancelScheduledExpiration()
            }
            return ChromeIntegrationState(
                extensionDirectory: extensionDirectory,
                temporaryShortcut: shortcutExists ? shortcut : nil,
                errorMessage: nil
            )
        } catch {
            return ChromeIntegrationState(
                extensionDirectory: nil,
                temporaryShortcut: nil,
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
            scheduleExpiration()
            return ChromeIntegrationState(
                extensionDirectory: extensionDirectory,
                temporaryShortcut: shortcut,
                errorMessage: nil
            )
        } catch {
            return ChromeIntegrationState(
                extensionDirectory: nil,
                temporaryShortcut: nil,
                errorMessage: error.localizedDescription
            )
        }
    }

    static func cancelInstallation() -> ChromeIntegrationState {
        cleanUpTemporaryInstaller()
        return status()
    }

    /// Removes the installer created by this app, never a foreign file with the same name.
    /// Called on normal app termination and by the one-hour expiration task.
    static func cleanUpTemporaryInstaller() {
        cancelScheduledExpiration()
        if let extensionDirectory = try? bundledExtensionDirectory() {
            _ = try? ChromeExtensionShortcut.removeIfOwned(
                at: temporaryShortcutURL(),
                expectedDestination: extensionDirectory
            )
        }
    }

    /// Keeps the native host ready without trying to guess whether Chrome has the extension.
    /// A shortcut left by an interrupted previous run is also removed on the next launch.
    static func prepareIntegration() {
        cleanUpTemporaryInstaller()
        try? installNativeHostManifest(fileManager: .default)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downbender")
        cleanupLegacyCopies(appSupportDirectory: support, fileManager: .default)
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

    private static func isOwnedShortcut(_ shortcut: URL, destination: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: shortcut.path),
              let values = try? shortcut.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink == true
        else { return false }
        return shortcut.resolvingSymlinksInPath().standardizedFileURL
            == destination.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func scheduleExpiration() {
        cancelScheduledExpiration()
        let expiration = Date().addingTimeInterval(installerLifetime)
        UserDefaults.standard.set(expiration, forKey: expirationKey)
        expirationTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(installerLifetime))
            } catch {
                return
            }
            cleanUpTemporaryInstaller()
        }
    }

    private static func removeExpiredTemporaryShortcut(now: Date = Date()) {
        guard let expiration = UserDefaults.standard.object(forKey: expirationKey) as? Date,
              expiration <= now
        else { return }
        cleanUpTemporaryInstaller()
    }

    private static func cancelScheduledExpiration() {
        expirationTask?.cancel()
        expirationTask = nil
        UserDefaults.standard.removeObject(forKey: expirationKey)
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
