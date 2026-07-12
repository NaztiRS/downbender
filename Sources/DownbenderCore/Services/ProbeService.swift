import Foundation

public enum ProbeError: Error, Equatable {
    case ytdlpFailed(String)
    case badOutput
}

extension ProbeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .ytdlpFailed(let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "yt-dlp failed with no error message." : trimmed
        case .badOutput:
            return "yt-dlp returned unexpected output."
        }
    }
}

public struct ProbeService: Sendable {
    let runner: ProcessRunning
    let ytdlpURL: URL
    let denoURL: URL?

    public init(runner: ProcessRunning, ytdlpURL: URL, denoURL: URL? = nil) {
        self.runner = runner
        self.ytdlpURL = ytdlpURL
        self.denoURL = denoURL
    }

    /// `cookiesBrowser` travels per call (not stored) so a Settings change applies to the next probe.
    public func probe(url: String, cookiesBrowser: String? = nil) async throws -> ProbeResult {
        let acc = Accumulator()
        let args = DownloadArgsBuilder.baseArgs(denoURL: denoURL, cookiesBrowser: cookiesBrowser) + ["-J", url]
        let result = try await runner.run(
            executableURL: ytdlpURL,
            arguments: args,
            onStdoutLine: { acc.append($0) }
        )
        guard result.exitCode == 0 else { throw ProbeError.ytdlpFailed(result.stderr) }
        guard let data = acc.text.data(using: .utf8), !data.isEmpty else { throw ProbeError.badOutput }
        return try FormatParser.parse(data)
    }
}
