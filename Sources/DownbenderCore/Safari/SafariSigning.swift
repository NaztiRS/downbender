import CryptoKit
import Foundation
import Security

/// A code-signing identity created with a free Apple ID in Xcode ("Apple Development: …").
public struct SafariSigningIdentity: Codable, Equatable, Sendable {
    public let sha1: String
    public let name: String

    public init(sha1: String, name: String) {
        self.sha1 = sha1
        self.name = name
    }
}

public enum SafariCertificateStatus: Equatable, Sendable {
    case ready([SafariSigningIdentity])
    /// The identity exists but macOS cannot build its chain: Apple's WWDR G3 intermediate is missing.
    case needsAppleIntermediate
    /// The identity exists and the intermediate is present, but it is not valid (expired, revoked).
    case unusable
    case missing
}

public enum SafariSigningError: LocalizedError, Equatable {
    case notAppleIntermediate
    case importFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAppleIntermediate:
            "The bundled Apple certificate does not match Apple's published file."
        case .importFailed(let details):
            "Could not add Apple's certificate to your keychain. \(details)"
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Reads the user's free signing certificate through `/usr/bin/security`. Nothing here creates a
/// certificate: that needs the user's Apple ID in Xcode.
public enum SafariSigning {
    public static let appleWWDRG3SHA1 = "06EC06599F4ED0027CC58956B4D3AC1255114F35"
    public static let appleWWDRG3SHA256 = "DCF21878C77F4198E4B4614F03D696D89C66C66008D4244E1B99161AAC91601F"

    private static let security = URL(fileURLWithPath: "/usr/bin/security")
    private static let identityPrefix = "Apple Development: "
    private static let intermediateName = "Apple Worldwide Developer Relations Certification Authority"

    public static func identities(fromFindIdentityOutput lines: [String]) -> [SafariSigningIdentity] {
        var seen = Set<String>()
        var result: [SafariSigningIdentity] = []
        for line in lines {
            // Invalid identities end with the reason, e.g. `"Apple Development: …" (CSSMERR_TP_CERT_EXPIRED)`.
            guard let match = line.wholeMatch(of: /\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"(?:\s+\(.*\))?\s*/)
            else { continue }
            let sha1 = String(match.1).uppercased()
            let name = String(match.2)
            guard name.hasPrefix(identityPrefix), seen.insert(sha1).inserted else { continue }
            result.append(SafariSigningIdentity(sha1: sha1, name: name))
        }
        return result
    }

    public static func containsAppleIntermediate(findCertificateOutput lines: [String]) -> Bool {
        lines.contains { $0.trimmingCharacters(in: .whitespaces) == "SHA-1 hash: \(appleWWDRG3SHA1)" }
    }

    public static func status(
        valid: [SafariSigningIdentity],
        all: [SafariSigningIdentity],
        hasAppleIntermediate: Bool
    ) -> SafariCertificateStatus {
        if !valid.isEmpty { return .ready(valid) }
        if all.isEmpty { return .missing }
        return hasAppleIntermediate ? .unusable : .needsAppleIntermediate
    }

    /// `security find-certificate -Z -p` prints each certificate's hashes followed by its PEM.
    public static func expirationDates(findCertificateOutput lines: [String]) -> [String: Date] {
        var expiries: [String: Date] = [:]
        var currentSHA1: String?
        var pem: [String]?
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("SHA-1 hash: ") {
                currentSHA1 = String(line.dropFirst("SHA-1 hash: ".count)).uppercased()
            } else if line == "-----BEGIN CERTIFICATE-----" {
                pem = []
            } else if line == "-----END CERTIFICATE-----" {
                defer { pem = nil }
                guard let sha1 = currentSHA1,
                      let body = pem,
                      let der = Data(base64Encoded: body.joined()),
                      let certificate = SecCertificateCreateWithData(nil, der as CFData),
                      let date = SecCertificateCopyNotValidAfterDate(certificate)
                else { continue }
                expiries[sha1] = date as Date
            } else if pem != nil {
                pem?.append(line)
            }
        }
        return expiries
    }

    public static func expirationDate(sha1: String, findCertificateOutput lines: [String]) -> Date? {
        expirationDates(findCertificateOutput: lines)[sha1.uppercased()]
    }

    public static func isGenuineAppleIntermediate(_ data: Data) -> Bool {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined() == appleWWDRG3SHA256
    }

    public static func detect(runner: ProcessRunning) async -> SafariCertificateStatus {
        let valid = await stdout(runner, ["find-identity", "-v", "-p", "codesigning"])
        let all = await stdout(runner, ["find-identity", "-p", "codesigning"])
        let intermediates = await stdout(runner, ["find-certificate", "-a", "-Z", "-c", intermediateName])
        return status(
            valid: identities(fromFindIdentityOutput: valid),
            all: identities(fromFindIdentityOutput: all),
            hasAppleIntermediate: containsAppleIntermediate(findCertificateOutput: intermediates)
        )
    }

    public static func expirationDate(
        for identity: SafariSigningIdentity,
        runner: ProcessRunning
    ) async -> Date? {
        await expirationDates(runner: runner)[identity.sha1]
    }

    /// Expiry of every "Apple Development" certificate in the keychain, keyed by SHA-1.
    public static func expirationDates(runner: ProcessRunning) async -> [String: Date] {
        let lines = await stdout(runner, ["find-certificate", "-a", "-Z", "-p", "-c", "Apple Development"])
        return expirationDates(findCertificateOutput: lines)
    }

    /// Adds Apple's public WWDR G3 intermediate to the login keychain. Trust settings are untouched;
    /// the intermediate only lets macOS build the chain from the user's certificate to Apple's root.
    public static func importAppleIntermediate(at url: URL, runner: ProcessRunning) async throws {
        guard isGenuineAppleIntermediate(try Data(contentsOf: url)) else {
            throw SafariSigningError.notAppleIntermediate
        }
        let keychain = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/login.keychain-db")
        let result = try await runner.run(
            executableURL: security,
            arguments: ["import", url.path, "-k", keychain.path],
            onStdoutLine: { _ in }
        )
        guard result.exitCode == 0 else { throw SafariSigningError.importFailed(result.stderr) }
    }

    private static func stdout(_ runner: ProcessRunning, _ arguments: [String]) async -> [String] {
        let lines = LineCollector()
        _ = try? await runner.run(executableURL: security, arguments: arguments, onStdoutLine: lines.append)
        return lines.lines
    }
}

/// Collects stdout lines delivered on the runner's reader queue.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
