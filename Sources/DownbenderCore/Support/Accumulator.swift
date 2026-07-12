import Foundation

public final class Accumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    public init() {}
    public func append(_ s: String) { lock.lock(); storage += s + "\n"; lock.unlock() }
    public var text: String { lock.lock(); defer { lock.unlock() }; return storage }
}
