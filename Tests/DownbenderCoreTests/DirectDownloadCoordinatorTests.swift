import Testing
import Foundation
@testable import DownbenderCore

private struct ScriptedDirectDownloader: DirectDownloading {
    struct Replay: Sendable {
        var progress: [DownloadProgress] = []
        var errorCode: URLError.Code?
        var gate: ProgressTestGate?
    }

    let replays: [Replay]
    let calls = CallCounter()
    let completedEmissions = CallCounter()

    // Mirrors the Core protocol so tests can drive every callback deterministically.
    // swiftlint:disable:next function_parameter_count
    func download(
        url _: String,
        destination: URL,
        tmpDirectory _: URL,
        suggestedName _: String?,
        maxBytes _: Int64?,
        allowInsecureHTTP _: Bool,
        resumeData _: Data?,
        session _: URLSession,
        onProgress: @Sendable @escaping (DownloadProgress) -> Void,
        onResumeData _: (@Sendable (Data) -> Void)?
    ) async throws -> URL {
        let index = calls.next()
        let replay = replays[min(index, replays.count - 1)]
        for progress in replay.progress {
            onProgress(progress)
        }
        _ = completedEmissions.next()
        if let gate = replay.gate {
            await gate.wait()
        }
        if let errorCode = replay.errorCode {
            throw URLError(errorCode)
        }
        return destination.appendingPathComponent("delivered.bin")
    }
}

// Added to the serialized DirectDownloadTests suite: these also drive the process-global mock.
extension DirectDownloadTests {
    @MainActor
    @Test func directCoordinatorDownloadsAndMarksDone() async throws {
        let dest = freshDir(); let tmp = freshDir()
        defer { try? FileManager.default.removeItem(at: dest); try? FileManager.default.removeItem(at: tmp) }
        MockURLProtocol.respond(status: 200, data: Data("hi".utf8), headers: ["Content-Type": "application/zip"])
        let coordinator = DirectDownloadCoordinator(service: DirectDownloadService(), maxBytes: nil,
                                                    sessionFactory: { MockURLProtocol.session() })
        let item = DownloadItem(url: "https://example.com/a.zip", title: "a.zip", destination: dest, state: .downloading)
        item.source = .directFile(DirectFileInfo(suggestedName: "a.zip"))

        await coordinator.run(item, tmpDirectory: tmp)

        #expect(item.state == .done)
        #expect(item.deliveredFileURL?.lastPathComponent == "a.zip")
        #expect(item.fraction == 1)
        #expect(item.indeterminateProgress == false)
    }

    @MainActor
    @Test func directCoordinatorMarksFailedOnAccessDenied() async throws {
        let dest = freshDir()
        defer { try? FileManager.default.removeItem(at: dest) }
        MockURLProtocol.respond(status: 403, data: Data())
        let coordinator = DirectDownloadCoordinator(service: DirectDownloadService(), maxBytes: nil,
                                                    sessionFactory: { MockURLProtocol.session() })
        let item = DownloadItem(
            url: "https://user:pass@example.com/a.zip?token=secret",
            title: "a.zip",
            destination: dest,
            state: .downloading
        )
        item.source = .directFile(DirectFileInfo())

        await coordinator.run(item, tmpDirectory: dest)
        guard case .failed(let msg) = item.state else { Issue.record("expected .failed"); return }
        #expect(msg.contains("Access denied"))
        #expect(item.failureDiagnostics?.operation == .directDownload)
        #expect(item.failureDiagnostics?.host == "example.com")
        #expect(item.failureDiagnostics?.engineChannel == nil)
        #expect(item.failureDiagnostics?.attempts.count == 1)
        #expect(item.failureDiagnostics?.report.contains("token=secret") == false)
        #expect(item.failureDiagnostics?.report.contains("user:pass") == false)
    }

    @MainActor
    @Test func directCoordinatorFailsWhenKnownSizeExceedsFreeSpace() async throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("dc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }

        let coordinator = DirectDownloadCoordinator(service: DirectDownloadService(), maxBytes: nil,
                                                    sessionFactory: { MockURLProtocol.session() })
        let item = DownloadItem(url: "https://example.com/huge.zip", title: "huge.zip", destination: dest, state: .downloading)
        item.source = .directFile(DirectFileInfo(suggestedName: "huge.zip", sizeBytes: Int64.max))

        await coordinator.run(item, tmpDirectory: dest)
        guard case .failed(let msg) = item.state else { Issue.record("expected .failed"); return }
        #expect(msg.contains("free space"))
        #expect(item.failureDiagnostics?.attempts.count == 1)
        #expect(item.failureDiagnostics?.report.contains("free space") == true)
    }

    @MainActor
    @Test func directCoordinatorDoesNotExposeRawFilesystemPathsInState() async throws {
        let dest = freshDir()
        defer { try? FileManager.default.removeItem(at: dest) }
        MockURLProtocol.handler = { _ in
            throw NSError(
                domain: "DirectDownloadTests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed at /Users/alice/My Videos/token=secret",
                ]
            )
        }
        let coordinator = DirectDownloadCoordinator(
            service: DirectDownloadService(),
            maxBytes: nil,
            sessionFactory: { MockURLProtocol.session() }
        )
        let item = DownloadItem(
            url: "https://example.com/a.zip",
            title: "a.zip",
            destination: dest,
            state: .downloading
        )
        item.source = .directFile(DirectFileInfo())

        await coordinator.run(item, tmpDirectory: dest)

        guard case .failed(let message) = item.state else {
            Issue.record("expected .failed")
            return
        }
        #expect(!message.contains("alice"))
        #expect(!message.contains("token=secret"))
        #expect(message.contains("<path>"))
    }

    @MainActor
    @Test func directCoordinatorCoalescesProgressStormAndForcesFinalValue() async {
        let gate = ProgressTestGate()
        let sleeper = ManualProgressSleeper()
        let progresses = (1...1_000).map { index in
            DownloadProgress(
                fraction: Double(index) / 1_001,
                speedText: "s\(index)",
                etaText: "",
                downloadedBytes: Int64(index),
                totalBytes: 1_001
            )
        }
        let downloader = ScriptedDirectDownloader(replays: [
            .init(progress: progresses, gate: gate),
        ])
        let coordinator = DirectDownloadCoordinator(
            downloader: downloader,
            maxBytes: nil,
            progressInterval: .milliseconds(250),
            progressSleep: { duration in await sleeper.sleep(for: duration) }
        )
        let item = DownloadItem(
            url: "https://example.com/file.bin",
            title: "file.bin",
            destination: URL(fileURLWithPath: "/tmp"),
            state: .downloading
        )
        item.source = .directFile(DirectFileInfo(suggestedName: "file.bin"))

        let run = Task {
            await coordinator.run(item, tmpDirectory: URL(fileURLWithPath: "/tmp/work"))
        }
        #expect(await waitForProgressCondition {
            abs(item.fraction - (1.0 / 1_001)) < 0.000_001
                && sleeper.waitingCount == 1
                && downloader.completedEmissions.count == 1
        })

        sleeper.advance()
        let publishedLatest = await waitForProgressCondition {
            abs(item.fraction - (1_000.0 / 1_001)) < 0.000_001 && sleeper.waitingCount == 1
        }
        #expect(
            publishedLatest,
            "fraction=\(item.fraction), waits=\(sleeper.waitingCount), requested=\(sleeper.requestedDurations.count)"
        )

        await gate.open()
        await run.value
        #expect(item.state == .done)
        #expect(item.fraction == 1)
        #expect(item.speedText == "s1000")
    }

    @MainActor
    @Test func directCoordinatorRetryDropsFailedAttemptsBufferedProgress() async {
        let gate = ProgressTestGate()
        let sleeper = ManualProgressSleeper()
        let downloader = ScriptedDirectDownloader(replays: [
            .init(
                progress: [
                    DownloadProgress(fraction: 0.2, speedText: "old-first", etaText: ""),
                    DownloadProgress(fraction: 0.9, speedText: "old-latest", etaText: ""),
                ],
                errorCode: .timedOut
            ),
            .init(gate: gate),
        ])
        let coordinator = DirectDownloadCoordinator(
            downloader: downloader,
            maxBytes: nil,
            retryDelay: .zero,
            progressInterval: .milliseconds(250),
            progressSleep: { duration in await sleeper.sleep(for: duration) }
        )
        let item = DownloadItem(
            url: "https://example.com/file.bin",
            title: "file.bin",
            destination: URL(fileURLWithPath: "/tmp"),
            state: .downloading
        )
        item.source = .directFile(DirectFileInfo(suggestedName: "file.bin"))

        let run = Task {
            await coordinator.run(item, tmpDirectory: URL(fileURLWithPath: "/tmp/work"))
        }
        #expect(await waitForProgressCondition {
            downloader.calls.count == 2 && item.state == .downloading
        })
        #expect(item.fraction == 0)
        #expect(item.speedText.isEmpty)

        sleeper.advanceAll()
        for _ in 0..<20 { await Task.yield() }
        #expect(item.fraction == 0)
        #expect(item.speedText.isEmpty)

        await gate.open()
        await run.value
        #expect(item.state == .done)
        #expect(item.fraction == 1)
        #expect(item.speedText.isEmpty)
    }
}
