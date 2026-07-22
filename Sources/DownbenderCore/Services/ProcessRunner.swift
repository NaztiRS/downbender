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
            let stderr = stderrBuffer.text
            return ProcessResult(exitCode: process.terminationStatus, stderr: stderr)
        } onCancel: {
            process.terminate()
        }
    }
}

/// Thread-safe stderr buffer with a blocking wait for EOF so the content is complete before reading.
final class StderrAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let doneSemaphore = DispatchSemaphore(value: 0)

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func markDone() {
        doneSemaphore.signal()
    }

    /// Bounded: if the EOF callback never fires (an orphaned grandchild can hold the pipe
    /// open after the child exits), return with what we have instead of hanging forever.
    func waitUntilDone(timeout: TimeInterval = 2) {
        _ = doneSemaphore.wait(timeout: .now() + timeout)
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
