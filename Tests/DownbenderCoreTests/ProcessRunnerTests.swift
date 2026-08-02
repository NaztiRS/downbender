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
    #expect(result.stderrOmittedBytes == 0)
}

@Test func processRunnerDrainsLargeStderrWithoutDeadlock() async throws {
    let sink = LineSink()
    let result = try await ProcessRunner().run(
        executableURL: URL(fileURLWithPath: "/bin/bash"),
        arguments: ["-c", "yes e | head -c 131072 >&2; echo done; exit 0"],
        onStdoutLine: { sink.append($0) }
    )
    #expect(result.exitCode == 0)
    #expect(sink.lines == ["done"])
    #expect(result.stderrOmittedBytes == 131_072 - StderrAccumulator.headByteLimit - StderrAccumulator.tailByteLimit)
    #expect(result.stderr.hasPrefix("e\n"))
    #expect(result.stderr.hasSuffix("e\n"))
    #expect(result.stderr.contains("\(result.stderrOmittedBytes) bytes omitted from stderr"))
}

@Test func stderrAccumulatorKeepsSmallOutputIntact() {
    let accumulator = StderrAccumulator()
    let message = "ERROR: café 🧪\n"

    accumulator.append(Data(message.utf8))

    #expect(accumulator.text == message)
    #expect(accumulator.omittedBytes == 0)
}

@Test func stderrAccumulatorKeepsHeadAndTailWhenTruncated() {
    let accumulator = StderrAccumulator()
    let middleByteCount = 4_096
    accumulator.append(Data(String(repeating: "H\n", count: StderrAccumulator.headByteLimit / 2).utf8))
    accumulator.append(Data(repeating: 0x4D, count: middleByteCount))
    accumulator.append(Data(("\n" + String(repeating: "T\n", count: StderrAccumulator.tailByteLimit / 2)).utf8))

    #expect(accumulator.omittedBytes == middleByteCount + 1)
    #expect(accumulator.text.hasPrefix("H\n"))
    #expect(accumulator.text.hasSuffix("T\n"))
    #expect(!accumulator.text.contains("MMMM"))
    #expect(accumulator.text.contains("\(middleByteCount + 1) bytes omitted from stderr"))
}

@Test func stderrAccumulatorDropsPartialLinesAtTruncationBoundaries() {
    let accumulator = StderrAccumulator()
    let secret = String(repeating: "cookie-canary-", count: 8_000)
    accumulator.append(Data("[debug] Cookie: \(secret)\nERROR: safe tail\n".utf8))

    #expect(accumulator.omittedBytes > 0)
    #expect(!accumulator.text.contains("cookie-canary"))
    #expect(accumulator.text.contains("ERROR: safe tail"))
}

@Test func stderrAccumulatorSalvagesInvalidUTF8() {
    let accumulator = StderrAccumulator()
    accumulator.append(Data([0x45, 0x52, 0x52, 0x4F, 0x52, 0x3A, 0x20, 0xFF, 0x20, 0x62, 0x6F, 0x6F, 0x6D]))

    #expect(accumulator.text.contains("ERROR:"))
    #expect(accumulator.text.contains("boom"))
    #expect(accumulator.text.contains("�"))
    #expect(accumulator.omittedBytes == 0)
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

/// A pipe hands over arbitrary chunks, so a line far bigger than its ~64 KB buffer arrives split.
/// `yt-dlp -J` answers with the whole probe as ONE line (600 KB+ for a YouTube video), and cutting
/// it anywhere makes the JSON unparseable.
@Test func processRunnerReassemblesALineLargerThanThePipeBuffer() async throws {
    let sink = LineSink()
    let result = try await ProcessRunner().run(
        executableURL: URL(fileURLWithPath: "/bin/bash"),
        arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' 'X'; echo"],
        onStdoutLine: { sink.append($0) }
    )
    #expect(result.exitCode == 0)
    #expect(sink.lines.count == 1)
    #expect(sink.lines.first?.count == 200_000)
}

@Test func processRunnerDeliversAFinalLineWithoutTrailingNewline() async throws {
    let sink = LineSink()
    _ = try await ProcessRunner().run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf 'sin-salto-final'"],
        onStdoutLine: { sink.append($0) }
    )
    #expect(sink.lines == ["sin-salto-final"])
}

@Test func processRunnerTreatsCarriageReturnLineFeedAsOneBreak() async throws {
    let sink = LineSink()
    _ = try await ProcessRunner().run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf 'uno\\r\\ndos\\r\\n'"],
        onStdoutLine: { sink.append($0) }
    )
    #expect(sink.lines == ["uno", "dos"])
}

/// A child that stays silent must not hold back the stdout of every other child. Reading with
/// `FileHandle.AsyncBytes` puts one blocking `read(2)` per process on a single serial executor,
/// so the slow reader takes it first and the fast children cannot finish until it writes.
@Test func silentChildDoesNotStallConcurrentRuns() async throws {
    let clock = ContinuousClock()
    let start = clock.now

    let slowestFast = await withTaskGroup(of: Duration?.self) { group in
        group.addTask {
            _ = try? await ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 2; echo lento"],
                onStdoutLine: { _ in }
            )
            return nil
        }
        // Give the silent child's reader time to take the executor before the fast ones queue up.
        try? await Task.sleep(for: .milliseconds(100))
        for _ in 0 ..< 4 {
            group.addTask {
                _ = try? await ProcessRunner().run(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "sleep 0.2; echo rapido"],
                    onStdoutLine: { _ in }
                )
                return clock.now - start
            }
        }
        var slowest = Duration.zero
        for await elapsed in group where elapsed != nil {
            slowest = max(slowest, elapsed!)
        }
        return slowest
    }

    // The fast children take ~0.3 s on their own and ~2 s when serialized behind the silent one.
    #expect(slowestFast < .seconds(1))
}

@Test func stderrAccumulatorWaitReturnsWithoutEOF() {
    // A child that leaves an orphan holding the stderr pipe never delivers EOF; the
    // bounded wait must return anyway with whatever was buffered.
    let accumulator = StderrAccumulator()
    accumulator.append(Data("partial stderr".utf8))
    let start = ContinuousClock.now
    accumulator.waitUntilDone(timeout: 0.2)
    #expect(ContinuousClock.now - start < .seconds(2))
    #expect(accumulator.text == "partial stderr")
}
