import Foundation

/// Bridges progress callbacks from background download engines to one rate-limited
/// MainActor consumer. The first value is preserved; while the consumer is sleeping,
/// all later values collapse into the most recent one.
final class ProgressCoalescer: @unchecked Sendable {
    typealias Sleep = @Sendable (Duration) async -> Void
    typealias Delivery = @MainActor @Sendable (DownloadProgress) -> Void

    static let defaultInterval: Duration = .milliseconds(250)

    private let state = PendingState()
    private let continuation: AsyncStream<Void>.Continuation
    private let delivery: Delivery
    private var consumer: Task<Void, Never>?

    @MainActor
    init(
        interval: Duration = defaultInterval,
        sleep: @escaping Sleep = liveSleep,
        delivery: @escaping Delivery
    ) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.continuation = continuation
        self.delivery = delivery

        let state = self.state
        consumer = Task { @MainActor in
            for await _ in stream {
                guard !Task.isCancelled else { break }
                guard let progress = state.takeNext() else { continue }
                delivery(progress)
                await sleep(interval)
                guard !Task.isCancelled else { break }

                // A signal may have been coalesced with the one just consumed before this
                // task started. Re-arm after the cadence wait whenever a latest value remains.
                if state.prepareNextSignal() {
                    continuation.yield()
                }
            }
        }
    }

    /// Thread-safe and intentionally synchronous: download callbacks do not create Tasks.
    func submit(_ progress: DownloadProgress) {
        guard state.submit(progress) else { return }
        continuation.yield()
    }

    /// Stops all pending work and synchronously delivers an exact terminal fraction.
    /// Calling this on MainActor serializes it against the sole consumer, so no stale
    /// buffered value can land after the terminal update.
    @MainActor
    func finish(at fraction: Double = 1) {
        let closed = state.close()
        guard closed.didClose else { return }
        continuation.finish()
        consumer?.cancel()
        consumer = nil

        let latest = closed.latest
        delivery(DownloadProgress(
            fraction: fraction,
            speedText: latest?.speedText ?? "",
            etaText: latest?.etaText ?? "",
            downloadedBytes: latest?.downloadedBytes,
            totalBytes: latest?.totalBytes
        ))
    }

    /// Drops buffered progress. Used on pause, cancellation, failure and before a retry.
    @MainActor
    func cancel() {
        guard state.close().didClose else { return }
        continuation.finish()
        consumer?.cancel()
        consumer = nil
    }

    /// Lets rare phase callbacks reject work queued by an attempt that already ended.
    var isActive: Bool { state.isActive }

    deinit {
        _ = state.close()
        continuation.finish()
        consumer?.cancel()
    }

    private static func liveSleep(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}

private final class PendingState: @unchecked Sendable {
    struct CloseResult {
        let didClose: Bool
        let latest: DownloadProgress?
    }

    private let lock = NSLock()
    private var first: DownloadProgress?
    private var latestPending: DownloadProgress?
    private var latestReceived: DownloadProgress?
    private var deliveredFirst = false
    /// True while a signal is buffered, being consumed, or the consumer is in its cadence wait.
    /// Keeping it set across the wait means callback storms only replace `latestPending`.
    private var signalScheduled = false
    private var closed = false

    func submit(_ progress: DownloadProgress) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }

        latestReceived = progress
        if !deliveredFirst, first == nil {
            first = progress
        } else {
            latestPending = progress
        }
        guard !signalScheduled else { return false }
        signalScheduled = true
        return true
    }

    func takeNext() -> DownloadProgress? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return nil }
        if let first {
            self.first = nil
            deliveredFirst = true
            return first
        }
        defer { latestPending = nil }
        return latestPending
    }

    /// Called by the consumer after its cadence wait. Either transfers ownership to the
    /// next buffered signal or clears the flag so a future submit can wake the consumer.
    func prepareNextSignal() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else {
            signalScheduled = false
            return false
        }
        if first != nil || latestPending != nil {
            return true
        }
        signalScheduled = false
        return false
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed
    }

    func close() -> CloseResult {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return CloseResult(didClose: false, latest: latestReceived) }
        closed = true
        first = nil
        latestPending = nil
        signalScheduled = false
        return CloseResult(didClose: true, latest: latestReceived)
    }
}
