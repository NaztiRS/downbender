import Observation
import DownbenderCore

/// One throttled observation pipeline shared by the Dock and menu-bar surfaces.
///
/// Observation tracking is deliberately left invalidated while the throttle task is pending:
/// a burst of raw progress mutations therefore schedules one refresh, not one Task per event.
@MainActor @Observable
final class SystemSurfaceQueueState {
    private(set) var snapshot = QueueActivitySnapshot()

    @ObservationIgnored private weak var queue: QueueViewModel?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var onSnapshotChange: (@MainActor (QueueActivitySnapshot) -> Void)?
    @ObservationIgnored private let minimumRefreshInterval: Duration

    init(minimumRefreshInterval: Duration = .milliseconds(250)) {
        self.minimumRefreshInterval = minimumRefreshInterval
    }

    func bind(
        to queue: QueueViewModel,
        onSnapshotChange: @escaping @MainActor (QueueActivitySnapshot) -> Void
    ) {
        refreshTask?.cancel()
        refreshTask = nil
        self.queue = queue
        self.onSnapshotChange = onSnapshotChange
        refreshAndObserve(forceNotification: true)
    }

    private func refreshAndObserve(forceNotification: Bool = false) {
        guard let queue else { return }
        let next = withObservationTracking {
            QueueActivitySnapshot(items: queue.items)
        } onChange: { [weak self] in
            // QueueViewModel and DownloadItem are MainActor-isolated, so their synchronous
            // Observation callback is necessarily delivered on the main actor.
            MainActor.assumeIsolated {
                self?.scheduleRefresh()
            }
        }

        let changed = next != snapshot
        if changed {
            snapshot = next
        }
        if changed || forceNotification {
            onSnapshotChange?(next)
        }
    }

    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        let interval = minimumRefreshInterval
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            self.refreshAndObserve()
        }
    }
}
