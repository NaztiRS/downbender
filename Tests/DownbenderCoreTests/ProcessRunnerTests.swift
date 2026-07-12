import Testing
import Foundation
@testable import DownbenderCore

final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ s: String) { lock.lock(); storage.append(s); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

@Test func processRunnerStreamsStdoutAndReturnsExitCode() async throws {
    let sink = LineSink()
    let result = try await ProcessRunner().run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "echo uno; echo dos; echo error 1>&2; exit 3"],
        onStdoutLine: { sink.append($0) }
    )
    #expect(sink.lines == ["uno", "dos"])
    #expect(result.exitCode == 3)
    #expect(result.stderr.contains("error"))
}

@Test func processRunnerDrainsLargeStderrWithoutDeadlock() async throws {
    let sink = LineSink()
    let result = try await ProcessRunner().run(
        executableURL: URL(fileURLWithPath: "/bin/bash"),
        arguments: ["-c", "head -c 131072 /dev/zero | tr '\\0' 'e' >&2; echo done; exit 0"],
        onStdoutLine: { sink.append($0) }
    )
    #expect(result.exitCode == 0)
    #expect(sink.lines == ["done"])
    #expect(result.stderr.count >= 131072)
}

@Test func processRunnerTerminatesOnCancellation() async throws {
    let task = Task {
        try await ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 5; echo tarde"],
            onStdoutLine: { _ in }
        )
    }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    let result = try await task.value
    #expect(result.exitCode != 0)   // terminated by signal, not exit 0
}
