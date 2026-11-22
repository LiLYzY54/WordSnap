import Network
import XCTest
@testable import WordSnap

final class DirectClientConcurrencyTests: XCTestCase {
    private enum StubError: Error { case failed }

    private actor TransportProbe {
        struct Snapshot {
            let connections: Int
            let connectionIPs: [String]
            let requests: [String]
            let maxConcurrentRequests: Int
        }

        private var connections = 0
        private var connectionIPs: [String] = []
        private var requests: [String] = []
        private var activeRequests = 0
        private var maxConcurrentRequests = 0
        private let pausedWords: Set<String>
        private let failingWords: Set<String>
        private var failuresBeforeSuccess: [String: Int]
        private let onStart: @Sendable (String) -> Void
        private var releasedWords: Set<String> = []
        private var pending: [String: CheckedContinuation<Void, Never>] = [:]

        init(pausedWords: Set<String> = [], failingWords: Set<String> = [],
             failuresBeforeSuccess: [String: Int] = [:],
             onStart: @escaping @Sendable (String) -> Void = { _ in }) {
            self.pausedWords = pausedWords
            self.failingWords = failingWords
            self.failuresBeforeSuccess = failuresBeforeSuccess
            self.onStart = onStart
        }

        func connect(_ ip: String) async throws -> NWConnection {
            connections += 1
            connectionIPs.append(ip)
            // Let simultaneous warmups enter while the first connection is pending.
            try await Task.sleep(nanoseconds: 2_000_000)
            // Never started: the tests perform no network I/O.
            return NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        }

        func exchange(_ connection: NWConnection, _ request: String) async throws -> Data {
            let target = request.components(separatedBy: " ")[1]
            let word = URLComponents(string: "https://example.invalid\(target)")?
                .queryItems?.first(where: { $0.name == "q" })?.value ?? ""
            requests.append(word)
            activeRequests += 1
            maxConcurrentRequests = max(maxConcurrentRequests, activeRequests)
            defer { activeRequests -= 1 }
            onStart(word)

            if pausedWords.contains(word), !releasedWords.contains(word) {
                // Like an in-flight NWConnection receive, this finishes only when
                // a response arrives, even if the awaiting lookup is cancelled.
                await withCheckedContinuation { pending[word] = $0 }
            } else {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            if failingWords.contains(word) { throw StubError.failed }
            if let remaining = failuresBeforeSuccess[word], remaining > 0 {
                failuresBeforeSuccess[word] = remaining - 1
                throw URLError(.networkConnectionLost)
            }
            return Data(word.utf8)
        }

        func release(_ word: String) {
            releasedWords.insert(word)
            pending.removeValue(forKey: word)?.resume()
        }

        func snapshot() -> Snapshot {
            Snapshot(connections: connections, connectionIPs: connectionIPs, requests: requests,
                     maxConcurrentRequests: maxConcurrentRequests)
        }
    }

    private func makeClient(_ probe: TransportProbe, ips: [String] = ["203.0.113.1"])
        -> WordService.YoudaoDirectClient {
        WordService.YoudaoDirectClient(ips: ips, transport: .init(
            connect: { try await probe.connect($0) },
            exchange: { try await probe.exchange($0, $1) }
        ))
    }

    func testConcurrentLookupsUseOneConnectionWithoutOverlappingExchanges() async throws {
        let probe = TransportProbe()
        let client = makeClient(probe)
        await client.warmUp()

        try await withThrowingTaskGroup(of: (String, Data).self) { group in
            for index in 0..<20 {
                let word = "word\(index)"
                group.addTask { (word, try await client.lookup(word)) }
            }
            for try await (word, data) in group {
                XCTAssertEqual(data, Data(word.utf8))
            }
        }

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.connections, 1)
        XCTAssertEqual(snapshot.requests.count, 20)
        XCTAssertEqual(snapshot.maxConcurrentRequests, 1)
    }

    func testFailureReleasesPermitAndNextLookupCreatesANewConnection() async throws {
        let started = expectation(description: "Failing request starts")
        let probe = TransportProbe(pausedWords: ["bad"], failingWords: ["bad"]) {
            if $0 == "bad" { started.fulfill() }
        }
        let client = makeClient(probe)
        let bad = Task { try await client.lookup("bad") }
        await fulfillment(of: [started], timeout: 2)
        let good = Task { try await client.lookup("good") }
        await probe.release("bad")

        do {
            _ = try await bad.value
            XCTFail("The failed response must be reported")
        } catch { XCTAssertTrue(error is StubError) }
        let data = try await good.value
        XCTAssertEqual(data, Data("good".utf8))
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.requests, ["bad", "good"])
        XCTAssertEqual(snapshot.connections, 2)
        XCTAssertEqual(snapshot.maxConcurrentRequests, 1)
    }

    func testConcurrentWarmupsAndLookupShareThePendingConnection() async throws {
        let probe = TransportProbe()
        let client = makeClient(probe)
        try await withThrowingTaskGroup(of: Data?.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await client.warmUp()
                    return nil
                }
            }
            group.addTask { try await client.lookup("hello") }
            for try await data in group {
                if let data { XCTAssertEqual(data, Data("hello".utf8)) }
            }
        }
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.connections, 1)
        XCTAssertEqual(snapshot.requests, ["hello"])
    }

    func testCancelledWaiterFinishesWithoutInterruptingActiveLookup() async throws {
        let started = expectation(description: "Active request starts")
        let cancelledFinished = expectation(description: "Cancelled waiter finishes before active response")
        let probe = TransportProbe(pausedWords: ["active"]) {
            if $0 == "active" { started.fulfill() }
        }
        let client = makeClient(probe)
        let active = Task { try await client.lookup("active") }
        await fulfillment(of: [started], timeout: 2)
        let cancelled = Task {
            defer { cancelledFinished.fulfill() }
            return try await client.lookup("cancelled")
        }
        cancelled.cancel()
        await fulfillment(of: [cancelledFinished], timeout: 2)
        await probe.release("active")

        do {
            _ = try await cancelled.value
            XCTFail("A cancelled waiter must throw")
        } catch { XCTAssertTrue(error is CancellationError) }
        let activeData = try await active.value
        XCTAssertEqual(activeData, Data("active".utf8))
        let nextData = try await client.lookup("next")
        XCTAssertEqual(nextData, Data("next".utf8))
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.connections, 1)
        XCTAssertEqual(snapshot.requests, ["active", "next"])
    }

    func testCancelledActiveLookupDoesNotRetryAndNextLookupStillWorks() async throws {
        let started = expectation(description: "Request starts before cancellation")
        let probe = TransportProbe(pausedWords: ["cancelled"]) {
            if $0 == "cancelled" { started.fulfill() }
        }
        let client = makeClient(probe, ips: ["203.0.113.1", "203.0.113.2"])
        await client.warmUp()
        let cancelled = Task { try await client.lookup("cancelled") }
        await fulfillment(of: [started], timeout: 2)
        cancelled.cancel()
        let next = Task { try await client.lookup("next") }
        await probe.release("cancelled")

        do {
            _ = try await cancelled.value
            XCTFail("The cancelled result must not be returned or retried")
        } catch { XCTAssertTrue(error is CancellationError) }
        let data = try await next.value
        XCTAssertEqual(data, Data("next".utf8))
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.requests, ["cancelled", "next"])
        XCTAssertEqual(snapshot.connections, 2)
        XCTAssertEqual(snapshot.maxConcurrentRequests, 1)
    }

    func testIdleConnectionFailureReconnectsToTheSameIPBeforeFailover() async throws {
        let probe = TransportProbe(failuresBeforeSuccess: ["apple": 1])
        let client = makeClient(probe, ips: ["203.0.113.1", "203.0.113.2"])
        await client.warmUp()

        let data = try await client.lookup("apple")
        XCTAssertEqual(data, Data("apple".utf8))
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.requests, ["apple", "apple"])
        XCTAssertEqual(snapshot.connectionIPs, ["203.0.113.1", "203.0.113.1"])
        XCTAssertEqual(snapshot.maxConcurrentRequests, 1)

        let next = try await client.lookup("next")
        XCTAssertEqual(next, Data("next".utf8))
        let finalSnapshot = await probe.snapshot()
        XCTAssertEqual(finalSnapshot.connections, 2, "The rebuilt connection must remain reusable")
    }

    func testReusedConnectionRetriesOnlyOnceThenReleasesThePermit() async throws {
        let probe = TransportProbe(failingWords: ["bad"])
        let client = makeClient(probe)
        await client.warmUp()

        do {
            _ = try await client.lookup("bad")
            XCTFail("Two failed attempts must be reported")
        } catch { XCTAssertTrue(error is StubError) }
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.requests, ["bad", "bad"])
        XCTAssertEqual(snapshot.connections, 2)

        let next = try await client.lookup("next")
        XCTAssertEqual(next, Data("next".utf8))
    }
}
