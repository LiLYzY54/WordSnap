import Foundation

/// Network completion and timeout callbacks can arrive on different queues.
/// Taking the continuation under the lock makes only one callback its owner.
final class OneShotContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(with result: Result<Value, Error>, beforeResume: () -> Void = {}) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()

        guard let pending else { return false }
        // The winner can release resources before the awaiting task continues.
        beforeResume()
        pending.resume(with: result)
        return true
    }
}
