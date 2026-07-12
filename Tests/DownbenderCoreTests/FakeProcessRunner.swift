import Foundation
@testable import DownbenderCore

/// Reference box so the test can observe the arguments FakeProcessRunner received:
/// the protocol requires a non-mutating `run`, so the struct cannot record into itself.
final class ArgumentRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private var perCall: [[String]] = []
    func record(_ args: [String]) { lock.lock(); storage = args; perCall.append(args); lock.unlock() }
    /// Arguments of the last call (classic behavior).
    var arguments: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    /// Arguments of EVERY call, in order (for per-attempt asserts in retries).
    var allArguments: [[String]] { lock.lock(); defer { lock.unlock() }; return perCall }
}

/// Thread-safe invocation counter; `next()` returns the 0-based index of the current call.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; let v = value; value += 1; return v }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

struct FakeProcessRunner: ProcessRunning {
    /// Result of ONE invocation, for per-call replays (retries).
    struct Replay {
        var stdoutLines: [String] = []
        var stderr: String = ""
        var exitCode: Int32 = 0
    }

    var stdoutLines: [String] = []
    var stderr: String = ""
    var exitCode: Int32 = 0
    /// Per-call results consumed in order (the last one repeats); nil = the flat fields apply to every call.
    var replays: [Replay]?
    var recordedArguments = ArgumentRecorder()
    var calls = CallCounter()

    func run(
        executableURL: URL,
        arguments: [String],
        onStdoutLine: @Sendable @escaping (String) -> Void
    ) async throws -> ProcessResult {
        recordedArguments.record(arguments)
        let index = calls.next()
        let replay: Replay
        if let replays, !replays.isEmpty {
            replay = replays[min(index, replays.count - 1)]
        } else {
            replay = Replay(stdoutLines: stdoutLines, stderr: stderr, exitCode: exitCode)
        }
        for line in replay.stdoutLines { onStdoutLine(line) }
        return ProcessResult(exitCode: replay.exitCode, stderr: replay.stderr)
    }
}
