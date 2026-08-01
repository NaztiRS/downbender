import Foundation
import Testing
@testable import DownbenderCore

@Test func diagnosticSanitizerRemovesSecretsURLsAndLocalPaths() {
    let raw = """
    [debug] Command-line config: ['--cookies-from-browser', 'chrome:Default']
    [debug] Cookie: SID=debug-cookie-secret; HSID=second-cookie-secret
    [debug] headers: {'Cookie': 'SID=inline-cookie-secret', 'Authorization': 'Basic inline-basic-secret'}
    [debug] headers: Cookie=loose-cookie-secret; HSID=loose-second-secret
    [debug] headers: Authorization=Basic loose-basic-secret extra-secret
    Authorization: Bearer bearer-secret
    Proxy-Authorization: Basic basic-secret
    Cookie: SID=cookie-secret
    Set-Cookie: session=set-cookie-secret
    args --cookies-from-browser chrome:Profile --password swordfish
    token=token-secret api_key=key-secret signature=sig-secret
    https://user:pass@rr.example.com/video?id=123&sig=url-secret#fragment
    file:///Users/alice/Library/Cookies.db
    output /Users/alice/Movies/private.mp4 and /tmp/downbender/work.part
    ERROR: HTTP Error 403: Forbidden
    Failed to resolve host
    """

    let safe = DiagnosticSanitizer.sanitize(raw)

    for secret in [
        "bearer-secret", "basic-secret", "cookie-secret", "debug-cookie-secret",
        "second-cookie-secret", "inline-cookie-secret", "inline-basic-secret",
        "loose-cookie-secret", "loose-second-secret", "loose-basic-secret", "extra-secret",
        "set-cookie-secret", "chrome:Default",
        "chrome:Profile", "swordfish", "token-secret", "key-secret", "sig-secret",
        "url-secret", "user:pass", "alice", "private.mp4", "work.part",
    ] {
        #expect(!safe.contains(secret))
    }
    #expect(safe.contains("--cookies-from-browser <redacted>"))
    #expect(safe.contains("--password <redacted>"))
    #expect(safe.contains("<url>"))
    #expect(safe.contains("<path>"))
    #expect(safe.contains("403: Forbidden"))
    #expect(safe.contains("Failed to resolve host"))
}

@Test func diagnosticSanitizerRemovesPathsWithSpacesAndTildes() {
    let raw = """
    output "/Users/alice/My Videos/private movie.mp4"
    cache ~/Library/Application Support/Downbender/cookies.sqlite
    file:///Users/alice/My Videos/private movie.mp4
    """

    let safe = DiagnosticSanitizer.sanitize(raw)

    #expect(!safe.contains("alice"))
    #expect(!safe.contains("My Videos"))
    #expect(!safe.contains("Application Support"))
    #expect(!safe.contains("private movie.mp4"))
    #expect(safe.contains("<path>"))
}

@Test func diagnosticLimitPreservesUsefulHeadAndTailWithinUTF8Budget() {
    let raw = "HEAD-🧪" + String(repeating: "middle", count: 1_000) + "-TAIL-403"

    let bounded = DiagnosticSanitizer.sanitizeAndLimit(raw, maxBytes: 1_024)

    #expect(bounded.hasPrefix("HEAD-🧪"))
    #expect(bounded.hasSuffix("-TAIL-403"))
    #expect(bounded.contains("output truncated"))
    #expect(bounded.utf8.count <= 1_024)
}

@Test func ytdlpFailureDetailsKeepsExitAndLastUsefulErrorSafely() {
    let result = ProcessResult(
        exitCode: 7,
        stderr: "[debug] build info\nWARNING: retrying\nERROR: failed at https://cdn.example/x?token=secret"
    )

    let details = YtdlpFailureDetails(result: result)

    #expect(details.exitCode == 7)
    #expect(details.summary == "ERROR: failed at <url>")
    #expect(details.output.contains("WARNING: retrying"))
    #expect(!details.output.contains("secret"))
}

@Test func ytdlpFailureDetailsKeepsTransientEvidenceOutsidePersistedAttemptWindow() {
    let result = ProcessResult(
        exitCode: 1,
        stderr: String(repeating: "head line\n", count: 900)
            + "HTTP Error 403: Forbidden\n"
            + String(repeating: "tail line\n", count: 900)
            + "ERROR: extractor stopped"
    )

    let details = YtdlpFailureDetails(result: result)
    let persistedAttempt = FailureAttempt(
        number: 1,
        exitCode: details.exitCode,
        detailed: false,
        summary: details.summary,
        output: details.output
    )

    #expect(TransientFailure.isTransient(DownloadError.ytdlpFailed(details)))
    #expect(details.output.contains("403: Forbidden"))
    #expect(persistedAttempt.output.utf8.count <= FailureAttempt.outputByteLimit)
}

@Test func ytdlpFailureDetailsPrefersActionableNonDebugSummary() {
    let result = ProcessResult(
        exitCode: 1,
        stderr: """
        [debug] Command-line config: --cookies-from-browser chrome
        ERROR: Sign in to confirm you're not a bot
        ERROR: extractor stopped
        """
    )

    let details = YtdlpFailureDetails(result: result)

    #expect(details.summary == "ERROR: Sign in to confirm you're not a bot")
    #expect(YtdlpErrorHint.hint(for: details.summary)?.suggestedAction == .openSettings)
}

@Test func failureDiagnosticsBuildsDeterministicPrivacySafeReport() {
    let diagnostics = FailureDiagnostics(
        appVersion: "1.7.0",
        systemVersion: "macOS Test",
        host: "youtube.com",
        operation: .download,
        engineChannel: .nightly,
        engineVersion: "2026.08.01.010203",
        outputDescription: "Up to 1080p · MP4",
        includeSubtitles: true,
        attempts: [FailureAttempt(
            number: 1,
            exitCode: 1,
            detailed: true,
            summary: "ERROR: unavailable",
            output: "Authorization: Bearer secret\nERROR: unavailable"
        )]
    )

    let report = diagnostics.report

    #expect(report.contains("Downbender diagnostics"))
    #expect(report.contains("App: 1.7.0"))
    #expect(report.contains("System: macOS Test"))
    #expect(report.contains("Operation: Media download"))
    #expect(report.contains("Host: youtube.com"))
    #expect(report.contains("Engine: Nightly · 2026.08.01.010203"))
    #expect(report.contains("Output: Up to 1080p · MP4"))
    #expect(report.contains("Subtitles: included"))
    #expect(report.contains("Attempt 1 · detailed logging"))
    #expect(report.contains("Exit code: 1"))
    #expect(report.contains("Authorization: <redacted>"))
    #expect(!report.contains("Bearer secret"))
}

@Test func diagnosticsKeepOnlyThreeMostRecentAttempts() {
    let attempts = (1...5).map {
        FailureAttempt(number: $0, exitCode: 1, detailed: false, summary: "e\($0)", output: "e\($0)")
    }
    let diagnostics = FailureDiagnostics(
        appVersion: "1",
        systemVersion: "macOS",
        host: "example.com",
        operation: .analysis,
        engineChannel: .stable,
        engineVersion: nil,
        outputDescription: nil,
        includeSubtitles: nil,
        attempts: attempts
    )

    #expect(diagnostics.attempts.map(\.number) == [3, 4, 5])
}

@Test func decodingFailureAttemptSanitizesUntrustedPersistedText() throws {
    let json = #"{"number":1,"exitCode":9,"detailed":true,"summary":"token=summary-secret","output":"Cookie: output-secret"}"#

    let decoded = try JSONDecoder().decode(FailureAttempt.self, from: Data(json.utf8))

    #expect(decoded.exitCode == 9)
    #expect(decoded.summary == "token=<redacted>")
    #expect(decoded.output == "Cookie: <redacted>")
    #expect(!decoded.summary.contains("summary-secret"))
    #expect(!decoded.output.contains("output-secret"))
}

@Test func diagnosticHostKeepsOnlyNormalizedHostname() {
    #expect(
        FailureDiagnostics.host(from: "https://user:pass@www.YouTube.com/watch?v=secret#fragment")
            == "youtube.com"
    )
    #expect(FailureDiagnostics.host(from: "not a URL") == "unknown")
}

@Test func mediaDiagnosticsWithoutPersistedEngineDoNotClaimNativeURLSession() {
    let diagnostics = FailureDiagnostics(
        appVersion: "1",
        systemVersion: "macOS",
        host: "example.com",
        operation: .download,
        engineChannel: nil,
        engineVersion: nil,
        outputDescription: nil,
        includeSubtitles: nil,
        attempts: []
    )

    #expect(diagnostics.report.contains("Engine: yt-dlp · channel and version unknown"))
    #expect(!diagnostics.report.contains("Native URLSession"))
}
