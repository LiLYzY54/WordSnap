import XCTest
@testable import WordSnap

final class AsyncRequestGateTests: XCTestCase {
    private func waitForQueuedCaller(in gate: AsyncRequestGate) async {
        let queued = expectation(description: "Caller is actually queued for the permit")
        let observer = Task {
            while !Task.isCancelled {
                if await gate.waitingCount == 1 {
                    queued.fulfill()
                    return
                }
                await Task.yield()
            }
        }
        await fulfillment(of: [queued], timeout: 2)
        observer.cancel()
    }

    func testCancellingAnEnqueuedWaiterDoesNotReleaseTheActivePermit() async throws {
        let gate = AsyncRequestGate()
        let activeStarted = expectation(description: "Active operation holds the permit")
        let cancelledFinished = expectation(description: "Queued cancellation completes while active is held")
        let releaseActive = AsyncStream<Void>.makeStream()
        defer { releaseActive.continuation.finish() }

        let active = Task {
            try await gate.withPermit {
                activeStarted.fulfill()
                var iterator = releaseActive.stream.makeAsyncIterator()
                _ = await iterator.next()
                return "active"
            }
        }
        await fulfillment(of: [activeStarted], timeout: 2)

        let cancelled = Task {
            defer { cancelledFinished.fulfill() }
            return try await gate.withPermit {
                XCTFail("A cancelled waiter must never run its operation")
                return "cancelled"
            }
        }
        await waitForQueuedCaller(in: gate)
        cancelled.cancel()

        // The stream is deliberately not released until cancellation has finished.
        await fulfillment(of: [cancelledFinished], timeout: 2)
        let waitingAfterCancellation = await gate.waitingCount
        XCTAssertEqual(waitingAfterCancellation, 0)

        let next = Task { try await gate.withPermit { "next" } }
        await waitForQueuedCaller(in: gate)
        let waitingBeforeRelease = await gate.waitingCount
        XCTAssertEqual(waitingBeforeRelease, 1, "Cancellation must not release the active owner's permit")

        releaseActive.continuation.yield(())
        releaseActive.continuation.finish()
        let activeValue = try await active.value
        let nextValue = try await next.value
        XCTAssertEqual(activeValue, "active")
        XCTAssertEqual(nextValue, "next")
        do {
            _ = try await cancelled.value
            XCTFail("The enqueued cancellation must throw")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}
