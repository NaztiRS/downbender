import Testing
import Foundation
@testable import DownbenderCore

@Test func parseSHA256SumsFindsTheExactFileLine() {
    // Real coreutils format from yt-dlp releases: 64 hex chars + TWO spaces + name.
    let sums = """
    111102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f  yt-dlp
    498bd0dae17855c599d371d68ec5bafc439a9d8640e838be25c765a9792f261b  yt-dlp_macos
    222202030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f  yt-dlp_macos.zip
    """
    #expect(UpdaterService.parseSHA256Sums(sums, file: "yt-dlp_macos")
        == "498bd0dae17855c599d371d68ec5bafc439a9d8640e838be25c765a9792f261b")
    // Exact-name match: never the .zip line, never a prefix match.
    #expect(UpdaterService.parseSHA256Sums(sums, file: "yt-dlp_macos.zip")
        == "222202030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    #expect(UpdaterService.parseSHA256Sums(sums, file: "missing") == nil)
}

@Test func parseSHA256SumsNormalizesCaseAndRejectsGarbage() {
    #expect(UpdaterService.parseSHA256Sums(
        "498BD0DAE17855C599D371D68EC5BAFC439A9D8640E838BE25C765A9792F261B  yt-dlp_macos",
        file: "yt-dlp_macos"
    ) == "498bd0dae17855c599d371d68ec5bafc439a9d8640e838be25c765a9792f261b")
    #expect(UpdaterService.parseSHA256Sums("not-a-hash  yt-dlp_macos", file: "yt-dlp_macos") == nil)
    #expect(UpdaterService.parseSHA256Sums("", file: "yt-dlp_macos") == nil)
}

@Test func sha256HexHashesAFile() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("ck-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("abc".utf8).write(to: file)
    // Well-known vector: SHA-256("abc").
    #expect(try UpdaterService.sha256Hex(of: file)
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

private final class UpdaterURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    // These are URLProtocol class-method overrides; `static` can't override a `class func`.
    // swiftlint:disable static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    // swiftlint:enable static_over_final_class

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdaterURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@Suite(.serialized)
struct UpdaterIntegrityTests {
    private let binaryURL = URL(string: "https://updates.example/yt-dlp_macos")!
    private let checksumsURL = URL(string: "https://updates.example/SHA2-256SUMS")!
    private let nightlyAPIURL = URL(string: "https://updates.example/nightly/latest")!
    private let abcChecksum = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    @Test func verifiedUpdateReplacesExistingBinaryAndMakesItExecutable() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("yt-dlp_macos")
        try Data("trusted old".utf8).write(to: installed)

        let binary = Data("abc".utf8)
        UpdaterURLProtocol.handler = { request in
            let data = request.url == checksumsURL
                ? Data("\(abcChecksum)  yt-dlp_macos\n".utf8)
                : binary
            return Self.response(for: request, status: 200, data: data)
        }
        let session = UpdaterURLProtocol.session()
        defer {
            session.invalidateAndCancel()
            UpdaterURLProtocol.handler = nil
        }

        let service = UpdaterService(appSupportDirectory: root)
        let result = try await service.updateYtdlp(
            session: session,
            binaryURL: binaryURL,
            checksumsURL: checksumsURL
        )

        #expect(result == installed)
        #expect(try Data(contentsOf: installed) == binary)
        let attributes = try FileManager.default.attributesOfItem(atPath: installed.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    }

    @Test func verifiedUpdateCanInstallTheFirstEngineCopy() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let binary = Data("abc".utf8)
        UpdaterURLProtocol.handler = { request in
            let data = request.url == checksumsURL
                ? Data("\(abcChecksum)  yt-dlp_macos\n".utf8)
                : binary
            return Self.response(for: request, status: 200, data: data)
        }
        let session = UpdaterURLProtocol.session()
        defer {
            session.invalidateAndCancel()
            UpdaterURLProtocol.handler = nil
        }

        let installed = try await UpdaterService(appSupportDirectory: root).updateYtdlp(
            session: session,
            binaryURL: binaryURL,
            checksumsURL: checksumsURL
        )

        #expect(try Data(contentsOf: installed) == binary)
        let attributes = try FileManager.default.attributesOfItem(atPath: installed.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    }

    @Test func checksumMismatchLeavesInstalledBinaryUntouched() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("yt-dlp_macos")
        let old = Data("trusted old".utf8)
        try old.write(to: installed)

        UpdaterURLProtocol.handler = { request in
            let data = request.url == checksumsURL
                ? Data("\(abcChecksum)  yt-dlp_macos\n".utf8)
                : Data("tampered".utf8)
            return Self.response(for: request, status: 200, data: data)
        }
        let session = UpdaterURLProtocol.session()
        defer {
            session.invalidateAndCancel()
            UpdaterURLProtocol.handler = nil
        }

        let service = UpdaterService(appSupportDirectory: root)
        await #expect(throws: UpdaterError.checksumMismatch(
            expected: abcChecksum,
            actual: "d121be3103007b41edf96f8262925f8c7d61894afe9a041843b631f69445bc57"
        )) {
            _ = try await service.updateYtdlp(
                session: session,
                binaryURL: binaryURL,
                checksumsURL: checksumsURL
            )
        }
        #expect(try Data(contentsOf: installed) == old)
    }

    @Test func missingChecksumStopsBeforeDownloadingBinary() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        UpdaterURLProtocol.handler = { request in
            guard request.url == checksumsURL else { throw URLError(.cannotLoadFromNetwork) }
            return Self.response(
                for: request,
                status: 200,
                data: Data("\(abcChecksum)  another-file\n".utf8)
            )
        }
        let session = UpdaterURLProtocol.session()
        defer {
            session.invalidateAndCancel()
            UpdaterURLProtocol.handler = nil
        }

        let service = UpdaterService(appSupportDirectory: root)
        await #expect(throws: UpdaterError.checksumNotFound("yt-dlp_macos")) {
            _ = try await service.updateYtdlp(
                session: session,
                binaryURL: binaryURL,
                checksumsURL: checksumsURL
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("yt-dlp_macos").path
        ))
    }

    @Test func latestVersionExercisesNetworkRequestAndResponse() async throws {
        let endpoint = URL(string: "https://updates.example/latest")!
        UpdaterURLProtocol.handler = { request in
            guard request.url == endpoint,
                  request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json",
                  request.value(forHTTPHeaderField: "User-Agent") == "Downbender"
            else {
                throw URLError(.badURL)
            }
            return Self.response(
                for: request,
                status: 200,
                data: Data(#"{"tag_name":"2026.07.25"}"#.utf8)
            )
        }
        let session = UpdaterURLProtocol.session()
        defer {
            session.invalidateAndCancel()
            UpdaterURLProtocol.handler = nil
        }

        let version = try await UpdaterService.latestVersion(session: session, from: endpoint)
        #expect(version == "2026.07.25")
    }

    @Test func nightlyAssetURLsArePinnedToOneOfficialRelease() throws {
        let tag = "2026.08.01.010203"
        let assets = try UpdaterService.nightlyAssetURLs(for: tag)

        #expect(assets.binary.absoluteString ==
            "https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/download/\(tag)/yt-dlp_macos")
        #expect(assets.checksums.absoluteString ==
            "https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/download/\(tag)/SHA2-256SUMS")
        #expect(throws: UpdaterError.badVersionOutput) {
            _ = try UpdaterService.nightlyAssetURLs(for: "../latest")
        }
    }

    @Test func verifiedNightlyReplacesOnlyNightlyAndReturnsItsVersion() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stable = root.appendingPathComponent("yt-dlp_macos")
        let nightly = root.appendingPathComponent("yt-dlp-nightly_macos")
        let stableData = Data("bundled or stable override".utf8)
        try stableData.write(to: stable)
        try Data("previous nightly".utf8).write(to: nightly)

        let tag = "2026.08.01.010203"
        let assets = try UpdaterService.nightlyAssetURLs(for: tag)
        let binary = Data("abc".utf8)
        UpdaterURLProtocol.handler = { request in
            let data: Data
            switch request.url {
            case self.nightlyAPIURL:
                data = Data(#"{"tag_name":"\#(tag)"}"#.utf8)
            case assets.checksums:
                data = Data("\(self.abcChecksum)  yt-dlp_macos\n".utf8)
            case assets.binary:
                data = binary
            default:
                throw URLError(.badURL)
            }
            return Self.response(for: request, status: 200, data: data)
        }
        let session = UpdaterURLProtocol.session()
        defer {
            session.invalidateAndCancel()
            UpdaterURLProtocol.handler = nil
        }

        let runner = FakeProcessRunner(stdoutLines: [tag])
        let result = try await UpdaterService(appSupportDirectory: root).installLatestNightly(
            session: session,
            runner: runner,
            latestReleaseURL: nightlyAPIURL
        )

        #expect(result == NightlyInstallResult(binaryURL: nightly, version: tag))
        #expect(try Data(contentsOf: nightly) == binary)
        #expect(try Data(contentsOf: stable) == stableData)
        #expect(runner.recordedArguments.arguments == ["--ignore-config", "--version"])
        let attributes = try FileManager.default.attributesOfItem(atPath: nightly.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy {
            !$0.hasSuffix(".candidate")
        })
    }

    @Test func nightlyChecksumFailureKeepsBothInstalledEnginesUntouched() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stable = root.appendingPathComponent("yt-dlp_macos")
        let nightly = root.appendingPathComponent("yt-dlp-nightly_macos")
        let stableData = Data("stable".utf8)
        let nightlyData = Data("trusted nightly".utf8)
        try stableData.write(to: stable)
        try nightlyData.write(to: nightly)

        let tag = "2026.08.01.010203"
        let assets = try UpdaterService.nightlyAssetURLs(for: tag)
        UpdaterURLProtocol.handler = { request in
            let data: Data
            switch request.url {
            case self.nightlyAPIURL:
                data = Data(#"{"tag_name":"\#(tag)"}"#.utf8)
            case assets.checksums:
                data = Data("\(self.abcChecksum)  yt-dlp_macos\n".utf8)
            case assets.binary:
                data = Data("tampered".utf8)
            default:
                throw URLError(.badURL)
            }
            return Self.response(for: request, status: 200, data: data)
        }
        let session = UpdaterURLProtocol.session()
        defer {
            session.invalidateAndCancel()
            UpdaterURLProtocol.handler = nil
        }

        let runner = FakeProcessRunner(stdoutLines: [tag])
        await #expect(throws: UpdaterError.checksumMismatch(
            expected: abcChecksum,
            actual: "d121be3103007b41edf96f8262925f8c7d61894afe9a041843b631f69445bc57"
        )) {
            _ = try await UpdaterService(appSupportDirectory: root).installLatestNightly(
                session: session,
                runner: runner,
                latestReleaseURL: nightlyAPIURL
            )
        }
        #expect(runner.recordedArguments.allArguments.isEmpty)
        #expect(try Data(contentsOf: nightly) == nightlyData)
        #expect(try Data(contentsOf: stable) == stableData)
    }

    @Test func invalidNightlyVersionOutputKeepsPreviousNightly() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nightly = root.appendingPathComponent("yt-dlp-nightly_macos")
        let old = Data("trusted nightly".utf8)
        try old.write(to: nightly)

        let tag = "2026.08.01.010203"
        let assets = try UpdaterService.nightlyAssetURLs(for: tag)
        UpdaterURLProtocol.handler = { request in
            let data: Data
            switch request.url {
            case self.nightlyAPIURL:
                data = Data(#"{"tag_name":"\#(tag)"}"#.utf8)
            case assets.checksums:
                data = Data("\(self.abcChecksum)  yt-dlp_macos\n".utf8)
            case assets.binary:
                data = Data("abc".utf8)
            default:
                throw URLError(.badURL)
            }
            return Self.response(for: request, status: 200, data: data)
        }
        let session = UpdaterURLProtocol.session()
        defer {
            session.invalidateAndCancel()
            UpdaterURLProtocol.handler = nil
        }

        let service = UpdaterService(appSupportDirectory: root)
        await #expect(throws: UpdaterError.badVersionOutput) {
            _ = try await service.installLatestNightly(
                session: session,
                runner: FakeProcessRunner(stdoutLines: ["   "]),
                latestReleaseURL: nightlyAPIURL
            )
        }
        #expect(try Data(contentsOf: nightly) == old)

        await #expect(throws: UpdaterError.versionMismatch(
            expected: tag,
            actual: "2026.07.31.235959"
        )) {
            _ = try await service.installLatestNightly(
                session: session,
                runner: FakeProcessRunner(stdoutLines: ["2026.07.31.235959"]),
                latestReleaseURL: nightlyAPIURL
            )
        }
        #expect(try Data(contentsOf: nightly) == old)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("updater-integrity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func response(
        for request: URLRequest,
        status: Int,
        data: Data
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Length": String(data.count)]
        )!
        return (response, data)
    }
}
