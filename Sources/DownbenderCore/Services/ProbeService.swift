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
    /// --flat-playlist: pure playlist URLs resolve to a light entry list in ONE call instead of
    /// N full extractions; single videos are unaffected, and --no-playlist (base args) still
    /// keeps watch?v=X&list=Y URLs as the single video the user pasted.
    /// `expandPlaylist: true` drops --no-playlist so a watch?v=X&list=Y URL resolves to the playlist.
    public func probe(url: String, cookiesBrowser: String? = nil, expandPlaylist: Bool = false) async throws -> ProbeOutcome {
        let acc = Accumulator()
        let args = DownloadArgsBuilder.baseArgs(denoURL: denoURL, cookiesBrowser: cookiesBrowser, noPlaylist: !expandPlaylist) + ["--flat-playlist", "-J", url]
        let result = try await runner.run(
            executableURL: ytdlpURL,
            arguments: args,
            onStdoutLine: { acc.append($0) }
        )
        guard result.exitCode == 0 else { throw ProbeError.ytdlpFailed(result.stderr) }
        guard let data = acc.text.data(using: .utf8), !data.isEmpty else { throw ProbeError.badOutput }
        return try FormatParser.parseOutcome(data)
    }
}
