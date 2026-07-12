import Testing
import Foundation
@testable import DownbenderCore

@Test func mediaInspectorParsesDimensionsFromFfprobeJSON() async {
    let json = #"{"streams":[{"width":1920,"height":1080}]}"#
    let runner = FakeProcessRunner(stdoutLines: [json], exitCode: 0)
    let inspector = MediaInspector(runner: runner, ffprobeURL: URL(fileURLWithPath: "/fake/ffprobe"))

    let dims = await inspector.videoDimensions(of: URL(fileURLWithPath: "/tmp/out/video.mp4"))
    #expect(dims?.width == 1920)
    #expect(dims?.height == 1080)
}

@Test func mediaInspectorReturnsNilWhenNoVideoStreams() async {
    let json = #"{"streams":[]}"#
    let runner = FakeProcessRunner(stdoutLines: [json], exitCode: 0)
    let inspector = MediaInspector(runner: runner, ffprobeURL: URL(fileURLWithPath: "/fake/ffprobe"))

    let dims = await inspector.videoDimensions(of: URL(fileURLWithPath: "/tmp/out/audio.mp3"))
    #expect(dims == nil)
}

@Test func mediaInspectorReturnsNilOnFfprobeFailure() async {
    let runner = FakeProcessRunner(stderr: "ERROR", exitCode: 1)
    let inspector = MediaInspector(runner: runner, ffprobeURL: URL(fileURLWithPath: "/fake/ffprobe"))

    let dims = await inspector.videoDimensions(of: URL(fileURLWithPath: "/tmp/out/broken.mp4"))
    #expect(dims == nil)
}
