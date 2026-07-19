import Foundation
import Testing
@testable import DownbenderCore

@Test func removesOnlyShortcutPointingToBundledExtension() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let extensionDirectory = root.appendingPathComponent("ChromeExtension", isDirectory: true)
    let shortcut = root.appendingPathComponent("Downbender Extension Installer", isDirectory: true)
    try fileManager.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(at: shortcut, withDestinationURL: extensionDirectory)
    defer { try? fileManager.removeItem(at: root) }

    #expect(try ChromeExtensionShortcut.removeIfOwned(
        at: shortcut,
        expectedDestination: extensionDirectory,
        fileManager: fileManager
    ))
    #expect(!fileManager.fileExists(atPath: shortcut.path))
}

@Test func preservesForeignItemWithInstallerName() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let extensionDirectory = root.appendingPathComponent("ChromeExtension", isDirectory: true)
    let foreignDirectory = root.appendingPathComponent("ForeignExtension", isDirectory: true)
    let shortcut = root.appendingPathComponent("Downbender Extension Installer", isDirectory: true)
    try fileManager.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: foreignDirectory, withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(at: shortcut, withDestinationURL: foreignDirectory)
    defer { try? fileManager.removeItem(at: root) }

    #expect(!(try ChromeExtensionShortcut.removeIfOwned(
        at: shortcut,
        expectedDestination: extensionDirectory,
        fileManager: fileManager
    )))
    #expect(fileManager.fileExists(atPath: shortcut.path))
}

@Test func missingTemporaryShortcutIsAlreadyClean() throws {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    #expect(!(try ChromeExtensionShortcut.removeIfOwned(
        at: missing,
        expectedDestination: missing.appendingPathComponent("ChromeExtension")
    )))
}
