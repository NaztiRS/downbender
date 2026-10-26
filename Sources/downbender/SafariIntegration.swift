import AppKit
import DownbenderCore
import Foundation

struct SafariIntegrationState: Equatable {
    var installedMode: SafariExtensionMode?
    var certificate: SafariCertificateStatus
    var attention: SafariAttention?
    var certificateExpiry: Date?
    /// Expiry of each valid Apple Development identity, keyed by SHA-1, for the certificate picker.
    var identityExpiries: [String: Date] = [:]
    var canInstall: Bool
    var errorMessage: String?
}

/// App-side glue for the Safari extension: Core decides and signs; this finds the bundled
/// resources, Application Support and Safari itself.
@MainActor
enum SafariIntegration {
    private static let runner = ProcessRunner()

    private static var resources: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("SafariExtension", isDirectory: true)
    }

    private static var templateArchive: URL? { bundledResource("DownbenderSafari.zip") }
    private static var entitlements: URL? { bundledResource("Sandbox.entitlements") }
    private static var appleIntermediate: URL? { bundledResource("AppleWWDRCAG3.cer") }

    private static var layout: SafariContainerLayout {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SafariContainerLayout(installRoot: support.appendingPathComponent("Downbender/Safari", isDirectory: true))
    }

    private static var installer: SafariContainerInstaller {
        SafariContainerInstaller(
            layout: layout,
            runner: runner,
            extractArchive: SafariContainerInstaller.dittoExtractor(runner: runner)
        )
    }

    private static var currentAppURL: URL { Bundle.main.bundleURL.standardizedFileURL }

    static func status(errorMessage: String? = nil) async -> SafariIntegrationState {
        let certificate = await SafariSigning.detect(runner: runner)
        var expiries: [String: Date] = [:]
        if case .ready = certificate { expiries = await SafariSigning.expirationDates(runner: runner) }
        let record = SafariInstallRecord.load(from: layout.recordURL)
        let installed = record != nil && FileManager.default.fileExists(atPath: layout.appURL.path)
        return SafariIntegrationState(
            installedMode: installed ? record?.mode : nil,
            certificate: certificate,
            attention: installed ? SafariStartupPolicy.attention(
                record: record,
                identityAvailable: identityAvailable(for: record, in: certificate),
                now: Date()
            ) : nil,
            certificateExpiry: installed ? record?.certificateExpiry : nil,
            identityExpiries: expiries,
            canInstall: !SafariStartupPolicy.isEphemeralLocation(currentAppURL) && templateArchive != nil,
            errorMessage: errorMessage
        )
    }

    static func install(mode: SafariExtensionMode) async -> SafariIntegrationState {
        do {
            try await performInstall(mode: mode, ownerAppPath: currentAppURL.path)
            openSafariExtensionSettings()
            return await status()
        } catch {
            return await status(errorMessage: error.localizedDescription)
        }
    }

    static func remove() async -> SafariIntegrationState {
        do {
            try await installer.remove()
        } catch {
            return await status(errorMessage: error.localizedDescription)
        }
        // Safari's sandbox data for the extension; macOS may refuse direct deletion.
        let containers = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers")
        let leftovers = [SafariContainerLayout.containerBundleID, SafariContainerLayout.extensionBundleID]
            .map { containers.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !leftovers.isEmpty {
            _ = try? await NSWorkspace.shared.recycle(leftovers)
        }
        return await status()
    }

    static func installAppleIntermediate() async -> SafariIntegrationState {
        guard let appleIntermediate else {
            return await status(errorMessage: SafariInstallError.unexpectedTemplate.localizedDescription)
        }
        do {
            try await SafariSigning.importAppleIntermediate(at: appleIntermediate, runner: runner)
            return await status()
        } catch {
            return await status(errorMessage: error.localizedDescription)
        }
    }

    /// After an update, rebuilds the installed copy from this version's template in the same mode,
    /// so Safari keeps it enabled; when the certificate is gone or expiring, re-signs with the newer
    /// one the user created. Never runs from a DMG and never re-signs ad hoc on its own.
    static func refreshAtLaunch() async {
        let layout = layout
        guard let record = SafariInstallRecord.load(from: layout.recordURL),
              FileManager.default.fileExists(atPath: layout.appURL.path),
              record.failedRefreshVersion != Downbender.version
        else { return }
        let certificate = await SafariSigning.detect(runner: runner)
        let ownerExists = FileManager.default.fileExists(atPath: record.ownerAppPath)
        if case .ready(let identities) = certificate {
            let expiries = await SafariSigning.expirationDates(runner: runner)
            if let renewal = SafariStartupPolicy.renewalIdentity(
                record: record,
                currentAppURL: currentAppURL,
                ownerExists: ownerExists,
                ready: identities,
                expiries: expiries,
                now: Date()
            ) {
                await refresh(record, mode: .permanent(identitySHA1: renewal.sha1))
                return
            }
        }
        guard SafariStartupPolicy.shouldRefresh(
            record: record,
            currentAppURL: currentAppURL,
            currentTemplateVersion: Downbender.version,
            ownerExists: ownerExists,
            identityAvailable: identityAvailable(for: record, in: certificate)
        ) else { return }
        await refresh(record, mode: record.mode)
    }

    /// A failure (e.g. a denied keychain prompt) is recorded so this version is not retried on
    /// every launch; Settings then offers Reinstall.
    private static func refresh(_ record: SafariInstallRecord, mode: SafariExtensionMode) async {
        do {
            try await performInstall(mode: mode, ownerAppPath: currentAppURL.path)
        } catch {
            var failed = record
            failed.failedRefreshVersion = Downbender.version
            try? failed.save(to: layout.recordURL)
        }
    }

    /// Safari only lets the extension's own container open its settings pane, so open Safari and
    /// let the panel say where to go.
    static func openSafariExtensionSettings() {
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: BrowserKind.safari.applicationBundleIdentifier)
        else { return }
        NSWorkspace.shared.openApplication(at: safari, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func performInstall(mode: SafariExtensionMode, ownerAppPath: String) async throws {
        guard let templateArchive, let entitlements else { throw SafariInstallError.unexpectedTemplate }
        var expiry: Date?
        if case .permanent(let sha1) = mode {
            guard case .ready(let identities) = await SafariSigning.detect(runner: runner),
                  let identity = identities.first(where: { $0.sha1 == sha1 })
            else { throw SafariInstallError.signingFailed("certificate not found") }
            expiry = await SafariSigning.expirationDate(for: identity, runner: runner)
        }
        _ = try await installer.install(
            templateArchive: templateArchive,
            entitlements: entitlements,
            mode: mode,
            ownerAppPath: ownerAppPath,
            templateVersion: Downbender.version,
            certificateExpiry: expiry
        )
    }

    private static func identityAvailable(for record: SafariInstallRecord?, in certificate: SafariCertificateStatus) -> Bool {
        guard case .permanent(let sha1) = record?.mode else { return true }
        guard case .ready(let identities) = certificate else { return false }
        return identities.contains { $0.sha1 == sha1 }
    }

    private static func bundledResource(_ name: String) -> URL? {
        guard let url = resources?.appendingPathComponent(name),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }
}
