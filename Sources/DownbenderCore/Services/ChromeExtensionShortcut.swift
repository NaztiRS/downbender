import Foundation

/// Removes only the temporary installer symlink created by Downbender. The strict destination
/// check prevents the native host from deleting an unrelated Downloads item with the same name.
public enum ChromeExtensionShortcut {
    public static func removeIfOwned(
        at shortcut: URL,
        expectedDestination: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: shortcut.path) else { return false }

        let values: URLResourceValues
        do {
            values = try shortcut.resourceValues(forKeys: [.isSymbolicLinkKey])
        } catch {
            let cocoaCode = CocoaError.Code(rawValue: (error as NSError).code)
            if cocoaCode == .fileNoSuchFile || cocoaCode == .fileReadNoSuchFile { return false }
            throw error
        }

        guard values.isSymbolicLink == true else { return false }
        let actualDestination = shortcut.resolvingSymlinksInPath().standardizedFileURL
        let ownedDestination = expectedDestination.resolvingSymlinksInPath().standardizedFileURL
        guard actualDestination == ownedDestination else { return false }

        try fileManager.removeItem(at: shortcut)
        return true
    }
}
