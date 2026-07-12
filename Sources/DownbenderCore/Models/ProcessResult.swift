import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stderr: String
    public init(exitCode: Int32, stderr: String) {
        self.exitCode = exitCode
        self.stderr = stderr
    }
}

public protocol ProcessRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        onStdoutLine: @Sendable @escaping (String) -> Void
    ) async throws -> ProcessResult
}
