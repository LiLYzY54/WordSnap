import XCTest
@testable import WordSnap

final class ChunkDecoderTests: XCTestCase {

    private func decoded(_ raw: String) -> ChunkDecoder.Outcome {
        var decoder = ChunkDecoder()
        return decoder.feed(Data(raw.utf8))
    }

    func testSingleChunkInOneFeed() {
        guard case .completed(let data) = decoded("5\r\nhello\r\n0\r\n\r\n") else {
            return XCTFail("expected completed")
        }
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello")
    }

    func testByteByByteFeeds() {
        var decoder = ChunkDecoder()
        let raw = Array("3\r\nabc\r\n0\r\n\r\n".utf8)
        for byte in raw.dropLast() {
            XCTAssertEqual(decoder.feed(Data([byte])), .needMore)
        }
        guard case .completed(let data) = decoder.feed(Data([raw.last!])) else {
            return XCTFail("expected completed on final byte")
        }
        XCTAssertEqual(String(data: data, encoding: .utf8), "abc")
    }

    func testMultipleChunks() {
        guard case .completed(let data) = decoded("3\r\nabc\r\n5\r\nworld\r\n0\r\n\r\n") else {
            return XCTFail("expected completed")
        }
        XCTAssertEqual(String(data: data, encoding: .utf8), "abcworld")
    }

    func testChunkExtensionIsIgnored() {
        guard case .completed(let data) = decoded("5;name=value\r\nhello\r\n0\r\n\r\n") else {
            return XCTFail("expected completed")
        }
        XCTAssertEqual(data, Data("hello".utf8))
    }

    func testTrailersAreConsumedForKeepAliveReuse() {
        // trailer 行必须被完整吃掉，否则残留字节会错位到下一个响应头
        guard case .completed(let data) = decoded("4\r\nWiki\r\n0\r\nX-Checksum: 1\r\n\r\n") else {
            return XCTFail("expected completed")
        }
        XCTAssertEqual(data, Data("Wiki".utf8))
    }

    func testPartialChunkWaitsForMoreData() {
        var decoder = ChunkDecoder()
        XCTAssertEqual(decoder.feed(Data("10\r\npartial".utf8)), .needMore)
    }

    func testInvalidSizeHexIsRejected() {
        XCTAssertEqual(decoded("zz\r\nhello\r\n0\r\n\r\n"), .invalid)
        XCTAssertEqual(decoded("-1\r\nx\r\n0\r\n\r\n"), .invalid)
    }
}
