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
