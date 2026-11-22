import XCTest
@testable import WordSnap

final class OneShotContinuationTests: XCTestCase {
    func testOnlyWinningCallbackCleansUpBeforeResuming() async throws {
        var cleanupCount = 0
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let completion = OneShotContinuation(continuation)
            XCTAssertTrue(completion.resume(with: .success(Data("response".utf8))) {
                cleanupCount += 1
            })
            XCTAssertFalse(completion.resume(with: .failure(URLError(.timedOut))) {
                cleanupCount += 1
            })
        }
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(data, Data("response".utf8))
    }

    func testNetworkResultIgnoresLateTimeout() async throws {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let completion = OneShotContinuation(continuation)
            XCTAssertTrue(completion.resume(with: .success(Data("response".utf8))))
            XCTAssertFalse(completion.resume(with: .failure(URLError(.timedOut))))
        }
        XCTAssertEqual(data, Data("response".utf8))
    }

    func testTimeoutIgnoresLateNetworkResult() async {
        do {
            let _: Data = try await withCheckedThrowingContinuation { continuation in
                let completion = OneShotContinuation(continuation)
                XCTAssertTrue(completion.resume(with: .failure(URLError(.timedOut))))
                XCTAssertFalse(completion.resume(with: .success(Data("late".utf8))))
            }
            XCTFail("The first timeout must remain the result")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }

    func testConcurrentTimeoutAndNetworkCallbacksResumeExactlyOnce() async {
        let attempts = 200
        let winners = expectation(description: "Exactly one callback wins each race")
        winners.expectedFulfillmentCount = attempts
        winners.assertForOverFulfill = true
        let finished = expectation(description: "Both callbacks finish every race")
        finished.expectedFulfillmentCount = attempts * 2
        let networkQueue = DispatchQueue(label: "test.wordsnap.network")

        for _ in 0..<attempts {
            do {
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    let completion = OneShotContinuation(continuation)
                    let deadline = DispatchTime.now() + .microseconds(20)
                    networkQueue.asyncAfter(deadline: deadline) {
                        if completion.resume(with: .success(Data("response".utf8))) {
                            winners.fulfill()
                        }
                        finished.fulfill()
                    }
                    DispatchQueue.global().asyncAfter(deadline: deadline) {
                        if completion.resume(with: .failure(URLError(.timedOut))) {
                            winners.fulfill()
                        }
                        finished.fulfill()
                    }
                }
                XCTAssertEqual(data, Data("response".utf8))
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .timedOut)
            }
        }
        await fulfillment(of: [winners, finished], timeout: 5)
    }
}
