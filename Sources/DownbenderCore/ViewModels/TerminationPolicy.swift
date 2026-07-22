import Foundation

/// What a quit would interrupt. Queued items count too: silently never running is as much
/// a loss as a killed transfer. The NSAlert itself stays in the app target (untestable UI).
@MainActor
public enum TerminationPolicy {
    public static func interruptedCount(_ items: [DownloadItem]) -> Int {
        items.filter { $0.state == .queued || $0.state == .downloading || $0.state == .merging }.count
    }
}
