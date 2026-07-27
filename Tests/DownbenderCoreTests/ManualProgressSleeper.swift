import Foundation

/// A cancellation-safe manual cadence used by progress tests. Advancing it never waits
/// for wall-clock time, so publication-count assertions remain deterministic.
final class ManualProgressSleeper: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var waiters: [Waiter] = []
    private var cancelledBeforeRegistration: Set<UUID> = []
    private var requested: [Duration] = []

    func sleep(for duration: Duration) async {
        let id = UUID()
        defer {
            clearCancellation(id)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                requested.append(duration)
                if cancelledBeforeRegistration.remove(id) != nil {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            cancel(id)
        }
    }

    var waitingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    var requestedDurations: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    func advance() {
        lock.lock()
        let waiter = waiters.isEmpty ? nil : waiters.removeFirst()
        lock.unlock()
        waiter?.continuation.resume()
    }

    func advanceAll() {
        lock.lock()
        let current = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in current {
            waiter.continuation.resume()
        }
    }

    private func cancel(_ id: UUID) {
        lock.lock()
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            lock.unlock()
            waiter.continuation.resume()
        } else {
            cancelledBeforeRegistration.insert(id)
            lock.unlock()
        }
    }

    private func clearCancellation(_ id: UUID) {
        lock.lock()
        cancelledBeforeRegistration.remove(id)
        lock.unlock()
    }
}

@MainActor
func waitForProgressCondition(
    iterations: Int = 1_000,
    _ condition: () -> Bool
) async -> Bool {
    for _ in 0..<iterations {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

actor ProgressTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let current = waiters
        waiters.removeAll()
        for waiter in current {
            waiter.resume()
        }
    }
}
