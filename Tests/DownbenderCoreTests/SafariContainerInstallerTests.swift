import Darwin
import Foundation
import Testing
@testable import DownbenderCore

private let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

/// A fake extracted template: two Info.plists with the expected identifiers and one executable.
private struct Sandbox {
    let root: URL
    let installRoot: URL
    let template: URL
    let entitlements: URL
    var layout: SafariContainerLayout { SafariContainerLayout(installRoot: installRoot) }

    init(extensionBundleID: String = SafariContainerLayout.extensionBundleID) throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        installRoot = root.appendingPathComponent("Application Support/Downbender/Safari", isDirectory: true)
        template = root.appendingPathComponent("template", isDirectory: true)
        entitlements = root.appendingPathComponent("Sandbox.entitlements")
        let app = template.appendingPathComponent(SafariContainerLayout.appName)
        let appex = app.appendingPathComponent(SafariContainerLayout.extensionRelativePath)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: appex.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Self.writePlist(["CFBundleIdentifier": SafariContainerLayout.containerBundleID], to: app)
        try Self.writePlist(["CFBundleIdentifier": extensionBundleID], to: appex)
        try Data("binary".utf8).write(to: app.appendingPathComponent("Contents/MacOS/DownbenderSafari"))
        try Data().write(to: entitlements)
    }

    static func writePlist(_ values: [String: String], to bundle: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    }

    /// Mirrors `ditto -x -k` from a quarantined download: the extracted files carry the flag.
    var extractor: @Sendable (URL, URL) async throws -> Void {
        let template = template
        return { _, destination in
            let name = SafariContainerLayout.appName
            try FileManager.default.copyItem(
                at: template.appendingPathComponent(name),
                to: destination.appendingPathComponent(name)
            )
            let binary = destination.appendingPathComponent("\(name)/Contents/MacOS/DownbenderSafari").path
            let flag = "0081;00000000;Safari;"
            _ = flag.withCString { setxattr(binary, "com.apple.quarantine", $0, flag.utf8.count, 0, 0) }
        }
    }

    func installer(_ runner: FakeProcessRunner) -> SafariContainerInstaller {
        SafariContainerInstaller(layout: layout, runner: runner, extractArchive: extractor)
    }

    func install(_ runner: FakeProcessRunner, mode: SafariExtensionMode = .quick) async throws -> SafariInstallRecord {
        try await installer(runner).install(
            templateArchive: root.appendingPathComponent("DownbenderSafari.zip"),
            entitlements: entitlements,
            mode: mode,
            ownerAppPath: "/Applications/Downbender.app",
            templateVersion: "1.9.0",
            certificateExpiry: nil
        )
    }

    func makeInstalledCopy() throws -> URL {
        let marker = layout.appURL.appendingPathComponent("Contents/previous-install")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker)
        return marker
    }

    func stagingLeftovers() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: installRoot.path)) ?? []
        return items.filter { $0.hasPrefix(".staging-") }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

/// Stores a value observed from inside the runner's `beforeReturn` hook.
private final class Observed: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

@Test func quickInstallSignsAdHocAndRegisters() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let runner = FakeProcessRunner()

    let record = try await sandbox.install(runner)

    let calls = runner.recordedArguments.allArguments
    let executables = runner.recordedArguments.allExecutableURLs.map(\.path)
    #expect(executables == ["/usr/bin/codesign", "/usr/bin/codesign", "/usr/bin/codesign", lsregister, "/usr/bin/pluginkit"])
    #expect(calls[0].prefix(5) == ["--force", "--sign", "-", "--entitlements", sandbox.entitlements.path])
    #expect(calls[0].last?.hasSuffix(SafariContainerLayout.extensionRelativePath) == true)
    #expect(calls[1].last?.hasSuffix(SafariContainerLayout.appName) == true)
    #expect(calls[2].prefix(3) == ["--verify", "--deep", "--strict"])
    #expect(calls[3] == ["-f", "-R", sandbox.layout.appURL.path])
    #expect(calls[4] == ["-a", sandbox.layout.extensionURL.path])
    #expect(FileManager.default.fileExists(atPath: sandbox.layout.extensionURL.appendingPathComponent("Contents/Info.plist").path))
    #expect(record == SafariInstallRecord(
        templateVersion: "1.9.0", mode: .quick, ownerAppPath: "/Applications/Downbender.app", certificateExpiry: nil
    ))
    #expect(SafariInstallRecord.load(from: sandbox.layout.recordURL) == record)
    #expect(sandbox.stagingLeftovers().isEmpty)
}

@Test func permanentInstallSignsWithIdentityHash() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let runner = FakeProcessRunner()
    let sha1 = "0123456789ABCDEF0123456789ABCDEF01234567"

    _ = try await sandbox.install(runner, mode: .permanent(identitySHA1: sha1))

    let signing = runner.recordedArguments.allArguments.prefix(2)
    #expect(signing.allSatisfy { Array($0.prefix(3)) == ["--force", "--sign", sha1] })
}

@Test func ownerPathIsWrittenBeforeSigning() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let observed = Observed()
    var runner = FakeProcessRunner()
    let recorder = runner.recordedArguments
    runner.beforeReturn = { call in
        guard call == 0, let appex = recorder.allArguments.first?.last else { return }
        let plist = URL(fileURLWithPath: appex).appendingPathComponent("Contents/Info.plist")
        let values = NSDictionary(contentsOf: plist)
        observed.value = values?[SafariContainerLayout.ownerPathInfoKey] as? String
    }

    _ = try await sandbox.install(runner)

    #expect(observed.value == "/Applications/Downbender.app")
}

@Test func quarantineIsStripped() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }

    _ = try await sandbox.install(FakeProcessRunner())

    let binary = sandbox.layout.appURL.appendingPathComponent("Contents/MacOS/DownbenderSafari").path
    #expect(getxattr(binary, "com.apple.quarantine", nil, 0, 0, 0) < 0)
}

@Test func unexpectedTemplateIsRejected() async throws {
    let sandbox = try Sandbox(extensionBundleID: "com.example.other")
    defer { sandbox.cleanUp() }
    let runner = FakeProcessRunner()

    await #expect(throws: SafariInstallError.unexpectedTemplate) {
        _ = try await sandbox.install(runner)
    }
    #expect(runner.recordedArguments.allArguments.isEmpty)
    #expect(sandbox.stagingLeftovers().isEmpty)
}

@Test func installFailureLeavesPreviousInstallUntouched() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let marker = try sandbox.makeInstalledCopy()
    let runner = FakeProcessRunner(replays: [.init(stderr: "errSecInternalComponent", exitCode: 1)])

    await #expect(throws: SafariInstallError.signingFailed("errSecInternalComponent")) {
        _ = try await sandbox.install(runner)
    }
    #expect(FileManager.default.fileExists(atPath: marker.path))
    #expect(runner.recordedArguments.allArguments.count == 1)
    #expect(sandbox.stagingLeftovers().isEmpty)
}

@Test func reinstallUnregistersPreviousCopyFirst() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let marker = try sandbox.makeInstalledCopy()
    let runner = FakeProcessRunner()

    _ = try await sandbox.install(runner)

    let calls = runner.recordedArguments.allArguments
    #expect(calls.count == 7)
    #expect(calls[3] == ["-r", sandbox.layout.extensionURL.path])
    #expect(calls[4] == ["-u", sandbox.layout.appURL.path])
    #expect(calls[5] == ["-f", "-R", sandbox.layout.appURL.path])
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func removeUnregistersAndDeletes() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    _ = try sandbox.makeInstalledCopy()
    try SafariInstallRecord(templateVersion: "1.9.0", mode: .quick, ownerAppPath: "/x", certificateExpiry: nil)
        .save(to: sandbox.layout.recordURL)
    let runner = FakeProcessRunner()

    try await sandbox.installer(runner).remove()

    #expect(runner.recordedArguments.allArguments == [
        ["-r", sandbox.layout.extensionURL.path],
        ["-u", sandbox.layout.appURL.path],
    ])
    #expect(!FileManager.default.fileExists(atPath: sandbox.layout.appURL.path))
    #expect(SafariInstallRecord.load(from: sandbox.layout.recordURL) == nil)
}
