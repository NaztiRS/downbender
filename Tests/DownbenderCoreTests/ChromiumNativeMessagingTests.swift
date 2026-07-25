import Foundation
import Testing
@testable import DownbenderCore

private struct InstalledNativeHostManifest: Decodable {
    let name: String
    let description: String
    let path: String
    let type: String
    let allowedOrigins: [String]

    private enum CodingKeys: String, CodingKey {
        case name, description, path, type
        case allowedOrigins = "allowed_origins"
    }
}

@Test func chromiumBrowsersUseTheirNativeMessagingDirectories() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    let expectedDirectories: [ChromiumBrowser: String] = [
        .chrome: "/Users/example/Library/Application Support/Google/Chrome/NativeMessagingHosts",
        .brave: "/Users/example/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts",
        .edge: "/Users/example/Library/Application Support/Microsoft Edge/NativeMessagingHosts",
        .chromium: "/Users/example/Library/Application Support/Chromium/NativeMessagingHosts",
    ]
    let expectedApplications: [ChromiumBrowser: (bundleID: String, extensionsPage: String)] = [
        .chrome: ("com.google.Chrome", "chrome://extensions/"),
        .brave: ("com.brave.Browser", "brave://extensions/"),
        .edge: ("com.microsoft.edgemac", "edge://extensions/"),
        .chromium: ("org.chromium.Chromium", "chrome://extensions/"),
    ]

    for browser in ChromiumBrowser.allCases {
        let manifest = ChromiumNativeMessaging.manifestURL(for: browser, homeDirectory: home)
        #expect(manifest.deletingLastPathComponent().path == expectedDirectories[browser])
        #expect(manifest.lastPathComponent == "\(BrowserBridge.nativeHostName).json")
        #expect(browser.applicationBundleIdentifier == expectedApplications[browser]?.bundleID)
        #expect(browser.extensionsPage == expectedApplications[browser]?.extensionsPage)
    }
}

@Test func installsAnIndependentValidManifestForEveryChromiumBrowser() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("downbender-native-host-\(UUID().uuidString)", isDirectory: true)
    let executable = root.appendingPathComponent("Downbender.app/Contents/MacOS/downbender-native-host")
    try fileManager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("host".utf8).write(to: executable)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    defer { try? fileManager.removeItem(at: root) }

    for browser in ChromiumBrowser.allCases {
        let destination = try ChromiumNativeMessaging.installDownbenderHost(
            executable: executable,
            for: browser,
            homeDirectory: root,
            fileManager: fileManager
        )
        let manifest = try JSONDecoder().decode(
            InstalledNativeHostManifest.self,
            from: Data(contentsOf: destination)
        )

        #expect(manifest.name == BrowserBridge.nativeHostName)
        #expect(manifest.description == "Send browser video links to Downbender")
        #expect(manifest.path == executable.path)
        #expect(manifest.type == "stdio")
        #expect(manifest.allowedOrigins == ["chrome-extension://\(BrowserBridge.chromeExtensionID)/"])
    }
}

@Test func refusesToRegisterANonExecutableNativeHost() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("downbender-native-host-\(UUID().uuidString)", isDirectory: true)
    let executable = root.appendingPathComponent("downbender-native-host")
    let destination = ChromiumNativeMessaging.manifestURL(for: .chrome, homeDirectory: root)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("host".utf8).write(to: executable)
    try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let previousManifest = Data("existing manifest".utf8)
    try previousManifest.write(to: destination)
    defer { try? fileManager.removeItem(at: root) }

    #expect(throws: ChromiumNativeMessagingError.hostNotExecutable(executable)) {
        try ChromiumNativeMessaging.installDownbenderHost(
            executable: executable,
            for: .chrome,
            homeDirectory: root,
            fileManager: fileManager
        )
    }
    #expect(try Data(contentsOf: destination) == previousManifest)
}

@Test func registrationOnlyCreatesTheSelectedBrowserManifest() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("downbender-native-host-\(UUID().uuidString)", isDirectory: true)
    let executable = root.appendingPathComponent("downbender-native-host")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("host".utf8).write(to: executable)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    defer { try? fileManager.removeItem(at: root) }

    try ChromiumNativeMessaging.installDownbenderHost(
        executable: executable,
        for: .brave,
        homeDirectory: root,
        fileManager: fileManager
    )

    for browser in ChromiumBrowser.allCases {
        let exists = fileManager.fileExists(
            atPath: ChromiumNativeMessaging.manifestURL(for: browser, homeDirectory: root).path
        )
        #expect(exists == (browser == .brave))
    }
}

@Test func registrationAtomicallyRefreshesAStaleExecutablePath() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("downbender-native-host-\(UUID().uuidString)", isDirectory: true)
    let oldExecutable = root.appendingPathComponent("Old.app/Contents/MacOS/downbender-native-host")
    let newExecutable = root.appendingPathComponent("New.app/Contents/MacOS/downbender-native-host")
    for executable in [oldExecutable, newExecutable] {
        try fileManager.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("host".utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    defer { try? fileManager.removeItem(at: root) }

    try ChromiumNativeMessaging.installDownbenderHost(
        executable: oldExecutable,
        for: .edge,
        homeDirectory: root,
        fileManager: fileManager
    )
    let destination = try ChromiumNativeMessaging.installDownbenderHost(
        executable: newExecutable,
        for: .edge,
        homeDirectory: root,
        fileManager: fileManager
    )
    let manifest = try JSONDecoder().decode(
        InstalledNativeHostManifest.self,
        from: Data(contentsOf: destination)
    )

    #expect(manifest.path == newExecutable.path)
    let remainingFiles = try fileManager.contentsOfDirectory(
        at: destination.deletingLastPathComponent(),
        includingPropertiesForKeys: nil
    )
    #expect(remainingFiles.map(\.lastPathComponent) == [destination.lastPathComponent])
}
