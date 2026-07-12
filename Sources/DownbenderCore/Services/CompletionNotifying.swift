/// Surfaces download-finished events to the app layer; a protocol keeps Core AppKit-free.
public protocol CompletionNotifying {
    @MainActor func downloadFinished(title: String, success: Bool, filePath: String?)
}
