import Foundation

public struct ProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        executableURL: URL,
        arguments: [String],
        onStdoutLine: @Sendable @escaping (String) -> Void
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain stderr in parallel: if the child fills the ~64 KB stderr pipe while we only
        // read stdout, it blocks on the write and stdout never reaches EOF → permanent deadlock.
        // The handler is installed BEFORE launch so the first bytes aren't lost.
        let stderrBuffer = StderrAccumulator()
        let errHandle = errPipe.fileHandleForReading
        errHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stderrBuffer.markDone()
            } else {
                stderrBuffer.append(data)
            }
        }

        // stdout is drained the same way, and for a stronger reason: `FileHandle.AsyncBytes`
        // (`.bytes.lines`) runs a BLOCKING read(2) on a single serial executor shared by the whole
        // process, so one silent child — `yt-dlp -J` says nothing until the extraction ends —
        // freezes the stdout of every other child in the app. Measured: 10 children sleeping
        // 1…10 s all finished at 10.0 s with `.bytes.lines`, and 1.0…10.0 s with this handler.
        // Unbounded buffering: dropping a line would lose the delivered-path marker.
        let outHandle = outPipe.fileHandleForReading
        let stdoutLines = AsyncStream<String>(bufferingPolicy: .unbounded) { continuation in
            let splitter = LineSplitter()
            continuation.onTermination = { _ in outHandle.readabilityHandler = nil }
            outHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    if let trailing = splitter.flush() { continuation.yield(trailing) }
                    continuation.finish()
                } else {
                    for line in splitter.take(data) { continuation.yield(line) }
                }
            }
        }

        do {
            try process.run()
        } catch {
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
            throw error
        }

        return await withTaskCancellationHandler {
            for await line in stdoutLines {
                onStdoutLine(line)
            }
            process.waitUntilExit()
            stderrBuffer.waitUntilDone()
            let stderr = stderrBuffer.snapshot
            return ProcessResult(
                exitCode: process.terminationStatus,
                stderr: stderr.text,
                stderrOmittedBytes: stderr.omittedBytes
            )
        } onCancel: {
            process.terminate()
        }
    }
}

/// Reassembles lines from the arbitrary chunks a pipe delivers, holding the partial tail until
/// its line break arrives. Both `\n` and `\r` break a line and `\r\n` counts as one, matching
/// what the previous `AsyncLineSequence` did: yt-dlp runs with `--newline`, but a bare `\r`
/// still shows up in some of its output.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func take(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        pending.append(chunk)
        var lines: [String] = []
        var lineStart = pending.startIndex
        var index = pending.startIndex
        while index < pending.endIndex {
            let byte = pending[index]
            guard byte == 0x0A || byte == 0x0D else {
                index = pending.index(after: index)
                continue
            }
            // swiftlint:disable:next optional_data_string_conversion
            lines.append(String(decoding: pending[lineStart ..< index], as: UTF8.self))
            var next = pending.index(after: index)
            if byte == 0x0D, next < pending.endIndex, pending[next] == 0x0A {
                next = pending.index(after: next)
            }
            lineStart = next
            index = next
        }
        // Rebuilding rebases the indices, so the next chunk starts from zero again.
        pending = Data(pending[lineStart...])
        return lines
    }

    /// Whatever is left when the pipe reaches EOF without a final line break.
    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard !pending.isEmpty else { return nil }
        // swiftlint:disable:next optional_data_string_conversion
        let trailing = String(decoding: pending, as: UTF8.self)
        pending = Data()
        return trailing
    }
}

/// Thread-safe stderr buffer that keeps the useful edges while continuing to drain the whole pipe.
final class StderrAccumulator: @unchecked Sendable {
    static let headByteLimit = 8 * 1_024
    static let tailByteLimit = 24 * 1_024
    private static let tailStorageByteLimit = tailByteLimit + 1

    private let lock = NSLock()
    private var head = Data()
    private var tail = Data()
    private var totalByteCount = 0
    private let doneSemaphore = DispatchSemaphore(value: 0)

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }

        totalByteCount += chunk.count
        let headBytes = min(Self.headByteLimit - head.count, chunk.count)
        if headBytes > 0 {
            head.append(contentsOf: chunk.prefix(headBytes))
        }

        let remaining = chunk.dropFirst(headBytes)
        if remaining.count >= Self.tailStorageByteLimit {
            tail = Data(remaining.suffix(Self.tailStorageByteLimit))
        } else {
            tail.append(contentsOf: remaining)
            if tail.count > Self.tailStorageByteLimit {
                tail.removeFirst(tail.count - Self.tailStorageByteLimit)
            }
        }
    }

    func markDone() {
        doneSemaphore.signal()
    }

    /// Bounded: if the EOF callback never fires (an orphaned grandchild can hold the pipe
    /// open after the child exits), return with what we have instead of hanging forever.
    func waitUntilDone(timeout: TimeInterval = 2) {
        _ = doneSemaphore.wait(timeout: .now() + timeout)
    }

    var snapshot: (text: String, omittedBytes: Int) {
        lock.lock()
        defer { lock.unlock() }

        let isTruncated = totalByteCount > Self.headByteLimit + Self.tailByteLimit
        let retainedHead = isTruncated ? completeLeadingLines(in: head) : head
        let retainedTail = isTruncated ? completeTrailingLines(in: tail) : tail
        let omittedBytes = max(totalByteCount - retainedHead.count - retainedTail.count, 0)
        var retained = retainedHead
        if omittedBytes > 0 {
            retained.append(contentsOf: "\n… \(omittedBytes) bytes omitted from stderr …\n".utf8)
        }
        retained.append(retainedTail)
        // yt-dlp can emit malformed bytes; lossy decoding preserves the useful text around them.
        // swiftlint:disable:next optional_data_string_conversion
        return (String(decoding: retained, as: UTF8.self), omittedBytes)
    }

    var text: String { snapshot.text }
    var omittedBytes: Int { snapshot.omittedBytes }

    /// The head begins at byte zero, so only its final partial line is unsafe at a cut.
    private func completeLeadingLines(in data: Data) -> Data {
        guard let lastBreak = data.lastIndex(where: Self.isLineBreak) else { return Data() }
        return Data(data[...lastBreak])
    }

    /// One extra context byte tells us whether the retained tail starts on a line boundary.
    /// Otherwise, discard through its first line break so no orphaned secret fragment survives.
    private func completeTrailingLines(in data: Data) -> Data {
        guard let context = data.first else { return Data() }
        let content = data.dropFirst()
        if Self.isLineBreak(context) { return Data(content) }
        guard let firstBreak = content.firstIndex(where: Self.isLineBreak) else { return Data() }
        return Data(content[content.index(after: firstBreak)...])
    }

    private static func isLineBreak(_ byte: UInt8) -> Bool {
        byte == 0x0A || byte == 0x0D
    }
}
