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

        try process.run()

        return try await withTaskCancellationHandler {
            for try await line in outPipe.fileHandleForReading.bytes.lines {
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
