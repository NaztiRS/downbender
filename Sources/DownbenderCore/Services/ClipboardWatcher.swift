import Foundation
import Observation

@MainActor @Observable
public final class ClipboardWatcher {
    public var detectedURL: String?
    private var lastSeen: String?

    public init() {}

    public func check(pasteboardString: String?) {
        guard let text = pasteboardString, let url = MediaURL.detect(in: text) else { return }
        guard url != lastSeen else { return }
        lastSeen = url
        detectedURL = url
    }
}
