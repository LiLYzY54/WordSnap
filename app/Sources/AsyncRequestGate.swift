import Foundation

/// Holds one permit across an entire async operation, including suspension points.
/// Cancelled waiters leave the queue without disturbing the operation using it.
actor AsyncRequestGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var occupied = false
    private var waiters: [Waiter] = []

    var waitingCount: Int { waiters.count }

    func withPermit<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire()
        do {
            // A waiter can be cancelled just as release() hands it the permit.
            try Task.checkCancellation()
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard occupied else {
            occupied = true
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}
