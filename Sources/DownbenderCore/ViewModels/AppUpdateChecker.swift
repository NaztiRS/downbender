import Foundation
import Observation

/// Silent launch check for a newer release: at most a dismissible banner, never a download or install.
@MainActor @Observable
public final class AppUpdateChecker {
    public static let releaseAPIURL = URL(string: "https://api.github.com/repos/NaztiRS/downbender/releases/latest")!
    public static let downloadPageURL = URL(string: "https://naztirs.github.io/downbender/")!

    public private(set) var availableVersion: String?
    public var dismissed = false

    private let installedVersion: String
    private let fetchLatest: @Sendable () async throws -> String

    public init(
        installedVersion: String = Downbender.version,
        fetchLatest: @escaping @Sendable () async throws -> String = {
            try await UpdaterService.latestVersion(from: AppUpdateChecker.releaseAPIURL)
        }
    ) {
        self.installedVersion = installedVersion
        self.fetchLatest = fetchLatest
    }

    /// Numeric semver comparison, tolerant of a leading "v" and missing components.
    nonisolated public static func isNewer(latestTag: String, than installed: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: ".").map { Int($0) ?? 0 }
        }
        let l = parts(latestTag)
        let i = parts(installed)
        for k in 0..<max(l.count, i.count) {
            let a = k < l.count ? l[k] : 0
            let b = k < i.count ? i[k] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// Offline or API failure = stay silent; this is a courtesy, not something the user asked for.
    public func check() async {
        guard let latest = try? await fetchLatest() else { return }
        if Self.isNewer(latestTag: latest, than: installedVersion) {
            availableVersion = latest.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        }
    }
}
