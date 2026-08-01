import Foundation
import Observation

@MainActor @Observable
public final class QueueViewModel {
    public private(set) var items: [DownloadItem] = []
    public var maxConcurrent: Int
    private var activeCount = 0
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let perform: @MainActor (DownloadItem) async -> Void

    /// Fired after every mutation that changes the item list or an item's scheduling —
    /// AppModel hangs queue persistence off this.
    public var onMutation: (@MainActor () -> Void)?

    public var hasLiveTasks: Bool { !tasks.isEmpty }
    /// Counts drive the batch-action bar; settled and not-yet-confirmed cards are excluded.
    public var pausableCount: Int { items.filter(isPausable).count }
    public var resumableCount: Int { items.filter { $0.state == .paused }.count }
    public var cancellableCount: Int { items.filter(isCancellable).count }

    public init(maxConcurrent: Int = 2, perform: @escaping @MainActor (DownloadItem) async -> Void) {
        self.maxConcurrent = maxConcurrent
        self.perform = perform
    }

    public func enqueue(_ item: DownloadItem) {
        items.append(item)
        pump()
        onMutation?()
    }

    /// Adds the card WITHOUT starting a download: items being probed or awaiting a quality pick.
    public func add(_ item: DownloadItem) {
        items.append(item)
        onMutation?()
    }

    public func start(_ item: DownloadItem) {
        guard item.state == .readyToChoose, item.format != nil else { return }
        item.state = .queued
        pump()
        onMutation?()
    }

    /// Starts a direct/ambiguous item (no format). The card was already added at detection time,
    /// so this reactivates it in place — re-appending here would duplicate the card.
    public func startDirect(_ item: DownloadItem) {
        guard item.state == .readyToChoose, item.source != .media else { return }
        item.state = .queued
        pump()
        onMutation?()
    }

    public func remove(_ item: DownloadItem) {
        tasks[item.id]?.cancel()
        tasks[item.id] = nil
        items.removeAll { $0.id == item.id }
        onMutation?()
    }

    /// Changes the priority of waiting work using SwiftUI's `onMove` index semantics.
    ///
    /// Running/finalizing work cannot move: apart from keeping the UI stable, validating the
    /// state again here closes the race where an item starts between beginning and ending a
    /// drag. Paused work can move because its position becomes its priority when it resumes.
    @discardableResult
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) -> Bool {
        guard !source.isEmpty,
              destination >= 0, destination <= items.count,
              source.allSatisfy({ items.indices.contains($0) }),
              source.allSatisfy({ canReorder(items[$0]) }) else { return false }

        let moving = source.sorted().map { items[$0] }
        var reordered = items
        for index in source.sorted(by: >) {
            reordered.remove(at: index)
        }

        // `destination` addresses the original collection. Removing source elements before it
        // shifts the insertion point left, matching Array/SwiftUI move behavior.
        let removedBeforeDestination = source.lazy.filter { $0 < destination }.count
        let insertionIndex = min(destination - removedBeforeDestination, reordered.count)
        reordered.insert(contentsOf: moving, at: insertionIndex)

        guard reordered.map(\.id) != items.map(\.id) else { return false }
        items = reordered
        onMutation?()
        return true
    }

    /// Only work whose scheduling priority can still change is draggable.
    public func canReorder(_ item: DownloadItem) -> Bool {
        item.state == .queued || item.state == .paused
    }

    public func cancel(_ item: DownloadItem) {
        guard cancelWithoutNotifying(item) else { return }
        onMutation?()
    }

    /// Pause: terminates the process but leaves the item resumable (yt-dlp continues the .part files).
    public func pause(_ item: DownloadItem) {
        guard pauseWithoutNotifying(item) else { return }
        onMutation?()
    }

    /// Pauses everything queued or running (the quit flow uses this before terminating).
    @discardableResult
    public func pauseAllActive() -> Int {
        let targets = items.filter(isPausable)
        guard !targets.isEmpty else { return 0 }
        for item in targets { _ = pauseWithoutNotifying(item) }
        onMutation?()
        return targets.count
    }

    /// True when the list holds anything a "Clear finished" would remove.
    public var hasSettledItems: Bool {
        items.contains { isSettled($0) }
    }

    /// Removes every settled item (done / failed / cancelled). Active, queued, paused and
    /// choosing items are never touched — retry a failure BEFORE clearing if you want it.
    public func clearSettled() {
        let settled = items.filter { isSettled($0) }
        guard !settled.isEmpty else { return }
        for entry in settled {
            tasks[entry.id]?.cancel()
            tasks[entry.id] = nil
        }
        items.removeAll { entry in settled.contains(where: { $0.id == entry.id }) }
        onMutation?()
    }

    private func isSettled(_ item: DownloadItem) -> Bool {
        switch item.state {
        case .done, .failed, .cancelled: return true
        default: return false
        }
    }

    public func resume(_ item: DownloadItem) {
        guard item.state == .paused else { return }
        prepareToResume(item)
        pump()
        onMutation?()
    }

    /// Resumes every paused download as one scheduling mutation. Existing concurrency limits
    /// still decide how many start; the rest remain queued.
    @discardableResult
    public func resumeAllPaused() -> Int {
        let targets = items.filter { $0.state == .paused }
        guard !targets.isEmpty else { return 0 }
        for item in targets { prepareToResume(item) }
        pump()
        onMutation?()
        return targets.count
    }

    /// Cancels queued, active and paused downloads. Analysis/choice cards and settled rows
    /// are intentionally untouched. Running tasks keep their execution state until they
    /// unwind so AppModel cannot sweep their temporary files out from under them.
    @discardableResult
    public func cancelAll() -> Int {
        let targets = items.filter(isCancellable)
        guard !targets.isEmpty else { return 0 }
        for item in targets { _ = cancelWithoutNotifying(item) }
        onMutation?()
        return targets.count
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
            onMutation?()
        default:
            break
        }
    }

    public func setMaxConcurrent(_ value: Int) {
        maxConcurrent = value
        pump()
    }

    private func isPausable(_ item: DownloadItem) -> Bool {
        item.state == .queued || item.state == .downloading || item.state == .merging
    }

    private func isCancellable(_ item: DownloadItem) -> Bool {
        isPausable(item) || item.state == .paused
    }

    private func pauseWithoutNotifying(_ item: DownloadItem) -> Bool {
        switch item.state {
        case .queued:
            item.state = .paused
        case .downloading, .merging:
            // State set BEFORE cancelling the Task: that's how the coordinator distinguishes pause from cancel.
            item.state = .paused
            tasks[item.id]?.cancel()
        default:
            return false
        }
        return true
    }

    private func cancelWithoutNotifying(_ item: DownloadItem) -> Bool {
        switch item.state {
        case .queued, .paused:
            item.state = .cancelled
            item.resumeData = nil
            item.nextEngineChannel = nil
        case .downloading, .merging:
            if let task = tasks[item.id] {
                task.cancel()
            } else {
                // Defensive: a restored/manually constructed execution state has no process
                // to unwind and mark it cancelled for us.
                item.state = .cancelled
                item.resumeData = nil
            }
        default:
            return false
        }
        return true
    }

    private func prepareToResume(_ item: DownloadItem) {
        item.speedText = ""
        item.etaText = ""
        item.state = .queued
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
                onMutation?()
                pump()
            }
            tasks[next.id] = task
        }
    }
}
