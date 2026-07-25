import Foundation

/// A compact, presentation-neutral snapshot of the queue for system surfaces such as
/// the Dock and menu bar. Keeping the aggregation in Core makes every surface agree.
public struct QueueActivitySummary: Equatable, Sendable {
    public let analyzingCount: Int
    public let choosingCount: Int
    public let runningCount: Int
    public let queuedCount: Int
    public let pausedCount: Int
    public let completedCount: Int
    public let failedCount: Int
    public let cancelledCount: Int
    /// Overall progress for downloads that are currently running or queued. `nil` means
    /// there is no active work, or at least one active transfer has an unknown total.
    public let progressFraction: Double?

    public var activeCount: Int { runningCount + queuedCount }
    public var pendingCount: Int { analyzingCount + choosingCount + activeCount + pausedCount }
    public var totalCount: Int {
        pendingCount + completedCount + failedCount + cancelledCount
    }

    @MainActor
    public init(items: [DownloadItem]) {
        var analyzing = 0
        var choosing = 0
        var running = 0
        var queued = 0
        var paused = 0
        var completed = 0
        var failed = 0
        var cancelled = 0
        var activeFractions: [Double] = []
        var hasIndeterminateActiveItem = false

        for item in items {
            switch item.state {
            case .probing:
                analyzing += 1
            case .probeFailed:
                failed += 1
            case .readyToChoose:
                choosing += 1
            case .queued:
                queued += 1
                activeFractions.append(clamp(item.fraction))
            case .downloading:
                running += 1
                activeFractions.append(clamp(item.fraction))
                hasIndeterminateActiveItem = hasIndeterminateActiveItem || item.indeterminateProgress
            case .merging:
                running += 1
                activeFractions.append(clamp(item.fraction))
            case .paused:
                paused += 1
            case .done:
                completed += 1
            case .failed:
                failed += 1
            case .cancelled:
                cancelled += 1
            }
        }

        analyzingCount = analyzing
        choosingCount = choosing
        runningCount = running
        queuedCount = queued
        pausedCount = paused
        completedCount = completed
        failedCount = failed
        cancelledCount = cancelled
        if activeFractions.isEmpty || hasIndeterminateActiveItem {
            progressFraction = nil
        } else {
            progressFraction = activeFractions.reduce(0, +) / Double(activeFractions.count)
        }
    }
}

private func clamp(_ value: Double) -> Double {
    min(1, max(0, value))
}
