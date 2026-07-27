import Foundation
import Testing
@testable import DownbenderCore

@MainActor
private final class ProgressPublicationRecorder {
    var values: [DownloadProgress] = []
}

@MainActor
@Test func progressCoalescerPreservesFirstAndPublishesOnlyLatestFromStorm() async {
    let sleeper = ManualProgressSleeper()
    let recorder = ProgressPublicationRecorder()
    let interval: Duration = .milliseconds(250)
    let coalescer = ProgressCoalescer(
        interval: interval,
        sleep: { duration in await sleeper.sleep(for: duration) },
        delivery: { progress in
            recorder.values.append(progress)
        }
    )

    for index in 1...1_000 {
        coalescer.submit(DownloadProgress(
            fraction: Double(index) / 1_001,
            speedText: "s\(index)",
            etaText: "e\(index)"
        ))
    }

    #expect(await waitForProgressCondition {
        recorder.values.count == 1 && sleeper.waitingCount == 1
    })
    #expect(recorder.values.count == 1)
    #expect(recorder.values[0].speedText == "s1")
    #expect(sleeper.requestedDurations == [interval])

    sleeper.advance()
    #expect(await waitForProgressCondition {
        recorder.values.count == 2 && sleeper.waitingCount == 1
    })
    #expect(recorder.values.count == 2)
    #expect(recorder.values[1].speedText == "s1000")
    #expect(recorder.values[1].etaText == "e1000")
    #expect(sleeper.requestedDurations == [interval, interval])

    coalescer.finish()
    #expect(recorder.values.count == 3)
    #expect(recorder.values.last?.fraction == 1)
    #expect(recorder.values.last?.speedText == "s1000")

    coalescer.submit(DownloadProgress(fraction: 0.2, speedText: "stale", etaText: "stale"))
    await Task.yield()
    #expect(recorder.values.count == 3)
}

@MainActor
@Test func progressCoalescerCancelDropsBufferedAndFutureValues() async {
    let sleeper = ManualProgressSleeper()
    let recorder = ProgressPublicationRecorder()
    let coalescer = ProgressCoalescer(
        sleep: { duration in await sleeper.sleep(for: duration) },
        delivery: { progress in
            recorder.values.append(progress)
        }
    )

    coalescer.submit(DownloadProgress(fraction: 0.1, speedText: "", etaText: ""))
    coalescer.submit(DownloadProgress(fraction: 0.9, speedText: "", etaText: ""))
    #expect(await waitForProgressCondition {
        recorder.values.count == 1 && sleeper.waitingCount == 1
    })

    coalescer.cancel()
    coalescer.submit(DownloadProgress(fraction: 1, speedText: "", etaText: ""))
    #expect(await waitForProgressCondition { sleeper.waitingCount == 0 })
    #expect(recorder.values.map(\.fraction) == [0.1])
}
