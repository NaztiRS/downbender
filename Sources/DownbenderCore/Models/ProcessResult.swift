import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stderr: String
    /// Number of stderr bytes discarded from the middle of `stderr` to keep the result bounded.
    public let stderrOmittedBytes: Int

    public init(exitCode: Int32, stderr: String, stderrOmittedBytes: Int = 0) {
        self.exitCode = exitCode
        self.stderr = stderr
        self.stderrOmittedBytes = stderrOmittedBytes
    }
}

public protocol ProcessRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        onStdoutLine: @Sendable @escaping (String) -> Void
    ) async throws -> ProcessResult
}
