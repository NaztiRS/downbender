import DownbenderCore
import Foundation

private enum NativeHostError: LocalizedError {
    case invalidHeader
    case messageTooLarge
    case incompleteMessage
    case unsupportedRequest
    case appUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidHeader: "Chrome sent an invalid native-messaging header."
        case .messageTooLarge: "The native-messaging request is too large."
        case .incompleteMessage: "Chrome closed the request before it was complete."
        case .unsupportedRequest: "The extension sent an unsupported or invalid URL."
        case .appUnavailable: "Downbender could not be opened. Is it installed?"
        }
    }
}

private func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
    var result = Data()
    while result.count < count {
        let chunk = handle.readData(ofLength: count - result.count)
        guard !chunk.isEmpty else { throw NativeHostError.incompleteMessage }
        result.append(chunk)
    }
    return result
}

private func readRequest() throws -> BrowserExtensionRequest {
    let input = FileHandle.standardInput
    let header = try readExactly(4, from: input)
    guard header.count == 4 else { throw NativeHostError.invalidHeader }
    let byteCount = header.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> UInt32 in
        rawBuffer.loadUnaligned(as: UInt32.self).littleEndian
    }
    guard byteCount > 0, byteCount <= 1_048_576 else { throw NativeHostError.messageTooLarge }
    let data = try readExactly(Int(byteCount), from: input)
    return try JSONDecoder().decode(BrowserExtensionRequest.self, from: data)
}

private func writeResponse(_ response: BrowserExtensionResponse) {
    guard let data = try? JSONEncoder().encode(response), data.count <= Int(UInt32.max) else { return }
    var length = UInt32(data.count).littleEndian
    let header = withUnsafeBytes(of: &length) { Data($0) }
    FileHandle.standardOutput.write(header)
    FileHandle.standardOutput.write(data)
}

private func openDownbender(_ deepLink: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [deepLink.absoluteString]
    // Child output must never reach stdout: Chrome reserves it for framed JSON messages.
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NativeHostError.appUnavailable }
}

private func cleanUpTemporaryInstaller() throws {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
    let extensionDirectory = contents.appendingPathComponent("Resources/ChromeExtension", isDirectory: true)
    let manifest = extensionDirectory.appendingPathComponent("manifest.json")
    guard FileManager.default.fileExists(atPath: manifest.path) else { throw NativeHostError.appUnavailable }

    let shortcut = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads/Downbender Extension Installer", isDirectory: true)
    _ = try ChromeExtensionShortcut.removeIfOwned(
        at: shortcut,
        expectedDestination: extensionDirectory
    )
}

do {
    let request = try readRequest()
    switch request.command {
    case "extension-installed":
        try cleanUpTemporaryInstaller()
    case "enqueue":
        guard let webURL = BrowserBridge.downloadURL(for: request),
              let deepLink = BrowserBridge.deepLink(for: webURL)
        else { throw NativeHostError.unsupportedRequest }
        try openDownbender(deepLink)
    default:
        throw NativeHostError.unsupportedRequest
    }
    writeResponse(BrowserExtensionResponse(ok: true))
} catch {
    writeResponse(BrowserExtensionResponse(ok: false, message: error.localizedDescription))
}
