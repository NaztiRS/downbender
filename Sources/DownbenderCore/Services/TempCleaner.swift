import Foundation

/// Purges yt-dlp's temp directory. .part filenames derive from video titles and can't be
/// mapped back to queue items reliably, so the rule is conservative: with nothing resumable
/// in the queue the directory empties; with paused/queued media items only stale entries go.
public enum TempCleaner {
    public static func sweep(
        tmpDirectory: URL,
        keepResumables: Bool,
        olderThan age: TimeInterval = 30 * 24 * 3600,
        now: Date = Date(),
        fileManager fm: FileManager = .default
    ) {
        guard let entries = try? fm.contentsOfDirectory(
            at: tmpDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        ) else { return }
        for entry in entries {
            if keepResumables {
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
                guard now.timeIntervalSince(modified) > age else { continue }
            }
            try? fm.removeItem(at: entry)
        }
    }
}
