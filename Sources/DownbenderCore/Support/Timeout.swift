import Foundation

public struct TimedOutError: Error, Equatable, Sendable {
    public init() {}
}

/// Races `operation` against a total deadline; whichever loses is cancelled. Cancelling the
/// surrounding task cancels both and surfaces the CancellationError (never a TimedOutError).
public func withTotalTimeout<T: Sendable>(
    _ timeout: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimedOutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
