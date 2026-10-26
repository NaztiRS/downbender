import Darwin
import Foundation

/// Where Downbender keeps the Safari container it manages. Users never open this app: Safari only
/// needs it registered so it can load the extension inside.
public struct SafariContainerLayout: Sendable {
    public static let containerBundleID = "com.naztirs.downbender.safari"
    public static let extensionBundleID = "com.naztirs.downbender.safari.extension"
    public static let appName = "Downbender for Safari.app"
    public static let extensionRelativePath = "Contents/PlugIns/DownbenderSafariExtension.appex"
    public static let ownerPathInfoKey = "DownbenderAppPath"

    public let installRoot: URL

    public init(installRoot: URL) {
        self.installRoot = installRoot
    }

    public var appURL: URL { installRoot.appendingPathComponent(Self.appName, isDirectory: true) }
    public var extensionURL: URL { appURL.appendingPathComponent(Self.extensionRelativePath, isDirectory: true) }
    public var recordURL: URL { installRoot.appendingPathComponent("install.json") }
}

public enum SafariInstallError: LocalizedError, Equatable {
    case unexpectedTemplate
    case signingFailed(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedTemplate:
            "The Safari extension bundled with Downbender is damaged. Reinstall Downbender."
        case .signingFailed:
            "Could not sign the Safari extension. If macOS asked to use your key, choose Always Allow and try again."
        case .verificationFailed:
            "The signed Safari extension did not pass verification."
        }
    }
}

/// Materializes the bundled template, signs it in the chosen mode and registers it. Everything
/// happens in a staging folder first, so a failed signature never touches the working install.
public struct SafariContainerInstaller: Sendable {
    private static let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
    private static let pluginkit = URL(fileURLWithPath: "/usr/bin/pluginkit")
    private static let lsregister = URL(fileURLWithPath:
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")

    let layout: SafariContainerLayout
    let runner: ProcessRunning
    let extractArchive: @Sendable (URL, URL) async throws -> Void

    public init(
        layout: SafariContainerLayout,
        runner: ProcessRunning,
        extractArchive: @escaping @Sendable (URL, URL) async throws -> Void
    ) {
        self.layout = layout
        self.runner = runner
        self.extractArchive = extractArchive
    }

    public static func dittoExtractor(runner: ProcessRunning) -> @Sendable (URL, URL) async throws -> Void {
        { archive, destination in
            let result = try await runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", archive.path, destination.path],
                onStdoutLine: { _ in }
            )
            guard result.exitCode == 0 else { throw SafariInstallError.unexpectedTemplate }
        }
    }

    // swiftlint:disable:next function_parameter_count
    public func install(
        templateArchive: URL,
        entitlements: URL,
        mode: SafariExtensionMode,
        ownerAppPath: String,
        templateVersion: String,
        certificateExpiry: Date?
    ) async throws -> SafariInstallRecord {
        let fileManager = FileManager.default
        let staging = layout.installRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try await extractArchive(templateArchive, staging)
        let stagedApp = staging.appendingPathComponent(SafariContainerLayout.appName, isDirectory: true)
        let stagedExtension = stagedApp.appendingPathComponent(SafariContainerLayout.extensionRelativePath)
        guard Self.bundleIdentifier(of: stagedApp) == SafariContainerLayout.containerBundleID,
              Self.bundleIdentifier(of: stagedExtension) == SafariContainerLayout.extensionBundleID
        else { throw SafariInstallError.unexpectedTemplate }

        Self.removeQuarantine(from: stagedApp)
        // The sandboxed extension reads this to open the Downbender copy that installed it.
        try Self.setInfoValue(ownerAppPath, forKey: SafariContainerLayout.ownerPathInfoKey, in: stagedExtension)

        let identity = switch mode {
        case .quick: "-"
        case .permanent(let sha1): sha1
        }
        for bundle in [stagedExtension, stagedApp] {
            let signed = try await run(Self.codesign, [
                "--force", "--sign", identity, "--entitlements", entitlements.path, bundle.path,
            ])
            guard signed.exitCode == 0 else { throw SafariInstallError.signingFailed(signed.stderr) }
        }
        let verified = try await run(Self.codesign, ["--verify", "--deep", "--strict", stagedApp.path])
        guard verified.exitCode == 0 else { throw SafariInstallError.verificationFailed(verified.stderr) }

        if fileManager.fileExists(atPath: layout.appURL.path) {
            await unregister()
            _ = try fileManager.replaceItemAt(layout.appURL, withItemAt: stagedApp)
        } else {
            try fileManager.moveItem(at: stagedApp, to: layout.appURL)
        }
        _ = try? await run(Self.lsregister, ["-f", "-R", layout.appURL.path])
        _ = try? await run(Self.pluginkit, ["-a", layout.extensionURL.path])

        let record = SafariInstallRecord(
            templateVersion: templateVersion,
            mode: mode,
            ownerAppPath: ownerAppPath,
            certificateExpiry: certificateExpiry
        )
        try record.save(to: layout.recordURL)
        return record
    }

    public func remove() async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: layout.appURL.path) {
            await unregister()
            try fileManager.removeItem(at: layout.appURL)
        }
        if fileManager.fileExists(atPath: layout.recordURL.path) {
            try fileManager.removeItem(at: layout.recordURL)
        }
    }

    /// A Downbender copied from a quarantined DMG passes the flag on to everything it extracts.
    public static func removeQuarantine(from root: URL) {
        var paths = [root.path]
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            for case let relative as String in enumerator {
                paths.append(root.appendingPathComponent(relative).path)
            }
        }
        for path in paths {
            _ = removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    private func unregister() async {
        _ = try? await run(Self.pluginkit, ["-r", layout.extensionURL.path])
        _ = try? await run(Self.lsregister, ["-u", layout.appURL.path])
    }

    private func run(_ executable: URL, _ arguments: [String]) async throws -> ProcessResult {
        try await runner.run(executableURL: executable, arguments: arguments, onStdoutLine: { _ in })
    }

    private static func bundleIdentifier(of bundle: URL) -> String? {
        NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String
    }

    private static func setInfoValue(_ value: String, forKey key: String, in bundle: URL) throws {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plist)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var values = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any]
        else { throw SafariInstallError.unexpectedTemplate }
        values[key] = value
        try PropertyListSerialization.data(fromPropertyList: values, format: format, options: 0)
            .write(to: plist, options: .atomic)
    }
}
