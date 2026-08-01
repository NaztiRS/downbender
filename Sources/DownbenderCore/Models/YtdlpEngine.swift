import Foundation

/// The two yt-dlp identities Downbender knows about. Stable always refers to the copy
/// inside the app bundle; nightly is the separately downloaded, replaceable copy.
public enum YtdlpEngineChannel: String, CaseIterable, Codable, Identifiable, Sendable {
    case stable
    case nightly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .stable: "Stable"
        case .nightly: "Nightly"
        }
    }
}

/// Snapshot taken when a probe or download starts. Keeping the absolute executable URL
/// beside the channel prevents a Settings change from switching engines mid-operation.
public struct YtdlpEngineDescriptor: Equatable, Sendable {
    public let channel: YtdlpEngineChannel
    public let executableURL: URL
    public let version: String?

    public init(channel: YtdlpEngineChannel, executableURL: URL, version: String? = nil) {
        self.channel = channel
        self.executableURL = executableURL
        self.version = version
    }
}

public struct YtdlpEngineInstallation: Equatable, Sendable {
    public let executableURL: URL
    public let version: String

    public init(executableURL: URL, version: String) {
        self.executableURL = executableURL
        self.version = version
    }
}

public enum YtdlpEngineSelectionError: Error, Equatable, LocalizedError {
    case nightlyNotInstalled
    case installationInProgress
    case unexpectedInstallLocation
    case validationFailed(String)
    case installationFailed(String, fallback: YtdlpEngineChannel)

    public var errorDescription: String? {
        switch self {
        case .nightlyNotInstalled:
            "Nightly isn't installed yet. Download the latest fixes first."
        case .installationInProgress:
            "The latest yt-dlp fixes are already being installed."
        case .unexpectedInstallLocation:
            "The nightly engine was installed in an unexpected location. Stable remains active."
        case .validationFailed(let message):
            "Nightly couldn't launch or report its version. Stable is active. \(message)"
        case .installationFailed(let message, let fallback):
            "Couldn't install the latest fixes. \(fallback.displayName) remains active. \(message)"
        }
    }
}
