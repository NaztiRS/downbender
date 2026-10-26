import Foundation

public enum SafariExtensionMode: Codable, Equatable, Sendable {
    /// Ad hoc signature: the user re-enables "Allow unsigned extensions" after each Safari quit.
    case quick
    /// Signed with the user's own free Apple Development certificate: works like a normal extension.
    case permanent(identitySHA1: String)
}

/// What Downbender installed for Safari, saved as `install.json` next to the container.
public struct SafariInstallRecord: Codable, Equatable, Sendable {
    public var templateVersion: String
    public var mode: SafariExtensionMode
    public var ownerAppPath: String
    public var certificateExpiry: Date?
    /// App version whose launch-time refresh failed (e.g. the keychain prompt was denied). That
    /// version is not retried on later launches, so the user is not prompted on every launch.
    public var failedRefreshVersion: String?

    public init(
        templateVersion: String,
        mode: SafariExtensionMode,
        ownerAppPath: String,
        certificateExpiry: Date?,
        failedRefreshVersion: String? = nil
    ) {
        self.templateVersion = templateVersion
        self.mode = mode
        self.ownerAppPath = ownerAppPath
        self.certificateExpiry = certificateExpiry
        self.failedRefreshVersion = failedRefreshVersion
    }

    public static func load(from url: URL) -> SafariInstallRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SafariInstallRecord.self, from: data)
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum SafariAttention: Equatable, Sendable {
    case updateFailed
    case certificateMissing
    case certificateExpiringSoon(Date)
    case certificateExpired(Date)
}

/// Pure launch-time decisions. Safari keys the extension by bundle ID and signing team, so a
/// refresh must keep the recorded mode and identity, and only one Downbender copy owns it.
public enum SafariStartupPolicy {
    private static let expiryWarning: TimeInterval = 30 * 86_400

    /// A Downbender opened from its DMG or an App Translocation path disappears later.
    public static func isEphemeralLocation(_ appURL: URL) -> Bool {
        let path = appURL.standardizedFileURL.path
        return path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }

    public static func shouldRefresh(
        record: SafariInstallRecord?,
        currentAppURL: URL,
        currentTemplateVersion: String,
        ownerExists: Bool,
        identityAvailable: Bool
    ) -> Bool {
        guard let record, !isEphemeralLocation(currentAppURL),
              record.failedRefreshVersion != currentTemplateVersion
        else { return false }
        if case .permanent = record.mode, !identityAvailable { return false }
        if record.ownerAppPath == currentAppURL.standardizedFileURL.path {
            return AppUpdateChecker.isNewer(latestTag: currentTemplateVersion, than: record.templateVersion)
        }
        if !ownerExists {
            return !AppUpdateChecker.isNewer(latestTag: record.templateVersion, than: currentTemplateVersion)
        }
        return false
    }

    public static func attention(record: SafariInstallRecord?, identityAvailable: Bool, now: Date) -> SafariAttention? {
        guard let record else { return nil }
        if record.failedRefreshVersion != nil { return .updateFailed }
        guard case .permanent = record.mode else { return nil }
        // An expired certificate also drops out of the valid identities, so check expiry first.
        if let expiry = record.certificateExpiry, expiry <= now { return .certificateExpired(expiry) }
        if !identityAvailable { return .certificateMissing }
        guard let expiry = record.certificateExpiry else { return nil }
        if expiry.timeIntervalSince(now) <= expiryWarning { return .certificateExpiringSoon(expiry) }
        return nil
    }

    /// The certificate to re-sign with when the recorded one is gone or about to expire: the valid
    /// identity that expires last, if it outlives the recorded one. Same Apple Account, same team,
    /// so Safari keeps the extension enabled.
    public static func renewalIdentity( // swiftlint:disable:this function_parameter_count
        record: SafariInstallRecord?,
        currentAppURL: URL,
        ownerExists: Bool,
        ready: [SafariSigningIdentity],
        expiries: [String: Date],
        now: Date
    ) -> SafariSigningIdentity? {
        guard let record, case .permanent(let recorded) = record.mode, !isEphemeralLocation(currentAppURL),
              record.ownerAppPath == currentAppURL.standardizedFileURL.path || !ownerExists
        else { return nil }
        let recordedAvailable = ready.contains { $0.sha1 == recorded }
        let expiringSoon = record.certificateExpiry.map { $0.timeIntervalSince(now) <= expiryWarning } ?? false
        guard !recordedAvailable || expiringSoon else { return nil }
        let floor = max(record.certificateExpiry ?? .distantPast, now)
        return ready
            .filter { $0.sha1 != recorded }
            .compactMap { identity in expiries[identity.sha1].map { (identity, $0) } }
            .filter { $0.1 > floor }
            .max { $0.1 < $1.1 }?.0
    }
}
