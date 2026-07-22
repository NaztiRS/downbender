import Foundation

/// One queue item flattened for disk — the Codable mirror of DownloadItem (@Observable
/// classes don't encode). Fine-grained progress (speed/eta) intentionally not persisted.
public struct PersistedItem: Codable, Equatable, Sendable {
    public var url: String
    public var title: String
    public var thumbnailURL: URL?
    public var formatID: String?
    public var includeSubtitles: Bool
    public var destinationPath: String
    public var state: String
    public var stateMessage: String?
    public var sourceKind: String // "media" | "directFile" | "ambiguous"
    public var suggestedName: String?
    public var sizeBytes: Int64?
    public var contentType: String?
    public var expectedTotalBytes: Int64?
    public var fraction: Double
    public var deliveredNote: String
    public var deliveredMismatch: Bool
    public var deliveredPath: String?
    public var resumeData: Data?
}

public extension PersistedItem {
    @MainActor
    init(_ item: DownloadItem) {
        url = item.url
        title = item.title
        thumbnailURL = item.thumbnailURL
        formatID = item.format?.id
        includeSubtitles = item.includeSubtitles
        destinationPath = item.destination.path
        let encoded = Self.encode(item.state)
        state = encoded.0
        stateMessage = encoded.1
        switch item.source {
        case .media:
            sourceKind = "media"
            suggestedName = nil
            sizeBytes = nil
            contentType = nil
        case .directFile(let info):
            sourceKind = "directFile"
            suggestedName = info.suggestedName
            sizeBytes = info.sizeBytes
            contentType = info.contentType
        case .ambiguous(let info):
            sourceKind = "ambiguous"
            suggestedName = info.suggestedName
            sizeBytes = info.sizeBytes
            contentType = info.contentType
        }
        expectedTotalBytes = item.expectedTotalBytes
        fraction = item.fraction
        deliveredNote = item.deliveredNote
        deliveredMismatch = item.deliveredMismatch
        deliveredPath = item.deliveredFileURL?.path
        resumeData = item.resumeData
    }

    /// Rebuilds a live item. Interrupted work comes back PAUSED (nothing self-starts on
    /// launch); probing items come back probing so AppModel re-runs the probe.
    @MainActor
    func makeItem() -> DownloadItem {
        let restored: DownloadItem.State
        switch state {
        case "probing": restored = .probing
        case "probeFailed": restored = .probeFailed(stateMessage ?? "Interrupted.")
        case "readyToChoose": restored = .readyToChoose
        case "queued", "downloading", "merging", "paused": restored = .paused
        case "done": restored = .done
        case "failed": restored = .failed(stateMessage ?? "Failed.")
        default: restored = .cancelled
        }
        let item = DownloadItem(
            url: url, title: title, thumbnailURL: thumbnailURL,
            format: formatID.flatMap(DownloadFormat.init(id:)),
            destination: URL(fileURLWithPath: destinationPath), state: restored
        )
        item.includeSubtitles = includeSubtitles
        switch sourceKind {
        case "directFile":
            item.source = .directFile(DirectFileInfo(suggestedName: suggestedName, sizeBytes: sizeBytes, contentType: contentType))
        case "ambiguous":
            item.source = .ambiguous(DirectFileInfo(suggestedName: suggestedName, sizeBytes: sizeBytes, contentType: contentType))
        default:
            item.source = .media
        }
        item.expectedTotalBytes = expectedTotalBytes
        item.fraction = fraction
        item.deliveredNote = deliveredNote
        item.deliveredMismatch = deliveredMismatch
        item.deliveredFileURL = deliveredPath.map { URL(fileURLWithPath: $0) }
        item.resumeData = resumeData
        return item
    }

    private static func encode(_ state: DownloadItem.State) -> (String, String?) {
        switch state {
        case .probing: return ("probing", nil)
        case .probeFailed(let message): return ("probeFailed", message)
        case .readyToChoose: return ("readyToChoose", nil)
        case .queued: return ("queued", nil)
        case .downloading: return ("downloading", nil)
        case .merging: return ("merging", nil)
        case .done: return ("done", nil)
        case .paused: return ("paused", nil)
        case .failed(let message): return ("failed", message)
        case .cancelled: return ("cancelled", nil)
        }
    }
}

struct PersistedQueue: Codable {
    var version: Int
    var items: [PersistedItem]
}

/// Saves/restores the queue across launches. Snapshots on the MainActor; the debounced
/// write happens off the hot path. A corrupt or unknown-version file yields a clean start —
/// persistence must never block the app from launching.
@MainActor
public final class QueuePersistence {
    public static let currentVersion = 1
    let fileURL: URL
    let debounce: Duration
    private var pendingSave: Task<Void, Never>?

    public init(fileURL: URL, debounce: Duration = .milliseconds(500)) {
        self.fileURL = fileURL
        self.debounce = debounce
    }

    public func load() -> [PersistedItem] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PersistedQueue.self, from: data),
              decoded.version == Self.currentVersion else { return [] }
        return decoded.items
    }

    public func scheduleSave(_ items: [DownloadItem]) {
        let snapshot = items.map(PersistedItem.init)
        pendingSave?.cancel()
        pendingSave = Task { [debounce, fileURL] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            Self.write(snapshot, to: fileURL)
        }
    }

    public func saveNow(_ items: [DownloadItem]) {
        pendingSave?.cancel()
        Self.write(items.map(PersistedItem.init), to: fileURL)
    }

    private static func write(_ items: [PersistedItem], to fileURL: URL) {
        guard let data = try? JSONEncoder().encode(PersistedQueue(version: currentVersion, items: items)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
