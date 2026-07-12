import Foundation

/// Inspects the delivered file with ffprobe (honesty check: actual pixels).
public struct MediaInspector: Sendable {
    let runner: ProcessRunning
    let ffprobeURL: URL

    public init(runner: ProcessRunning, ffprobeURL: URL) {
        self.runner = runner
        self.ffprobeURL = ffprobeURL
    }

    private struct FfprobeOutput: Decodable {
        struct Stream: Decodable { let width: Int?; let height: Int? }
        let streams: [Stream]
    }

    /// Dimensions of the first video stream, or nil if there is no video or ffprobe fails (best-effort).
    public func videoDimensions(of file: URL) async -> (width: Int, height: Int)? {
        let acc = Accumulator()
        let args = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=width,height",
            "-of", "json",
            file.path,
        ]
        guard let result = try? await runner.run(
            executableURL: ffprobeURL,
            arguments: args,
            onStdoutLine: { acc.append($0) }
        ), result.exitCode == 0 else { return nil }

        guard let data = acc.text.data(using: .utf8),
              let output = try? JSONDecoder().decode(FfprobeOutput.self, from: data),
              let first = output.streams.first,
              let width = first.width,
              let height = first.height
        else { return nil }

        return (width: width, height: height)
    }
}
