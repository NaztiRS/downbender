import Foundation
import Observation

@MainActor @Observable
public final class QueueViewModel {
    public private(set) var items: [DownloadItem] = []
    public var maxConcurrent: Int
    private var activeCount = 0
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let perform: @MainActor (DownloadItem) async -> Void

    public init(maxConcurrent: Int = 2, perform: @escaping @MainActor (DownloadItem) async -> Void) {
        self.maxConcurrent = maxConcurrent
        self.perform = perform
    }

    public func enqueue(_ item: DownloadItem) {
        items.append(item)
        pump()
    }

    /// Adds the card WITHOUT starting a download: items being probed or awaiting a quality pick.
    public func add(_ item: DownloadItem) {
        items.append(item)
    }

    public func start(_ item: DownloadItem) {
        guard item.state == .readyToChoose, item.format != nil else { return }
        item.state = .queued
        pump()
    }

    public func remove(_ item: DownloadItem) {
        tasks[item.id]?.cancel()
        tasks[item.id] = nil
        items.removeAll { $0.id == item.id }
    }

    public func cancel(_ item: DownloadItem) {
        switch item.state {
        case .queued, .paused:
            item.state = .cancelled
        default:
            tasks[item.id]?.cancel()
        }
    }

    /// Pause: terminates the process but leaves the item resumable (yt-dlp continues the .part files).
    public func pause(_ item: DownloadItem) {
        switch item.state {
        case .queued:
            item.state = .paused
        case .downloading, .merging:
            // State set BEFORE cancelling the Task: that's how the coordinator distinguishes pause from cancel.
            item.state = .paused
            tasks[item.id]?.cancel()
        default:
            break
        }
    }

    public func resume(_ item: DownloadItem) {
        guard item.state == .paused else { return }
        item.speedText = ""
        item.etaText = ""
        item.state = .queued
        pump()
    }

    public func retry(_ item: DownloadItem) {
        switch item.state {
        case .failed, .cancelled:
            item.fraction = 0
            item.speedText = ""
            item.etaText = ""
            item.deliveredNote = ""
            item.deliveredMismatch = false
            item.state = .queued
            pump()
        default:
            break
        }
    }

    public func setMaxConcurrent(_ value: Int) {
        maxConcurrent = value
        pump()
    }

    private func pump() {
        // tasks[id] == nil: a re-enqueued item whose previous Task is still unwinding must NOT
        // start a second process over the same .part files; that Task's cleanup re-pumps.
        while activeCount < maxConcurrent,
              let next = items.first(where: { $0.state == .queued && tasks[$0.id] == nil }) {
            activeCount += 1
            next.state = .downloading
            let task = Task { @MainActor in
                await perform(next)
                activeCount -= 1
                tasks[next.id] = nil
                pump()
            }
            tasks[next.id] = task
        }
    }
}
