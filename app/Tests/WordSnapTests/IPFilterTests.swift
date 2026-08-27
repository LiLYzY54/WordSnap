import XCTest
@testable import WordSnap

final class IPFilterTests: XCTestCase {

    func testRejectsFakeIPAndPrivateRanges() {
        // TUN fake-IP 池（Clash 默认 198.18.0.0/15）
        XCTAssertFalse(WordService.YoudaoDirectClient.isPlausiblePublicIPv4("198.18.0.1"))
        XCTAssertFalse(WordService.YoudaoDirectClient.isPlausiblePublicIPv4("198.19.255.254"))
        // 内网 / 环回 / 链路本地 / CGNAT
        XCTAssertFalse(WordService.YoudaoDirectClient.isPlausiblePublicIPv4("127.0.0.1"))
        XCTAssertFalse(WordService.YoudaoDirectClient.isPlausiblePublicIPv4("10.1.2.3"))
        XCTAssertFalse(WordService.YoudaoDirectClient.isPlausiblePublicIPv4("192.168.1.1"))
        XCTAssertFalse(WordService.YoudaoDirectClient.isPlausiblePublicIPv4("172.16.0.9"))
        XCTAssertFalse(WordService.YoudaoDirectClient.isPlausiblePublicIPv4("169.254.1.1"))
        XCTAssertFalse(WordService.YoudaoDirectClient.isPlausiblePublicIPv4("100.64.0.1"))
        // 格式垃圾
        XCTAssertFalse(WordService.YoudaoDirectClient.isPlausiblePublicIPv4("abc"))
        XCTAssertFalse(WordService.YoudaoDirectClient.isPlausiblePublicIPv4("1.2.3"))
    }

    func testAcceptsPublicAddresses() {
        XCTAssertTrue(WordService.YoudaoDirectClient.isPlausiblePublicIPv4("220.197.31.37"))
        XCTAssertTrue(WordService.YoudaoDirectClient.isPlausiblePublicIPv4("123.58.167.197"))
        // 198.20.x 不在 fake-IP 段内，应放行
        XCTAssertTrue(WordService.YoudaoDirectClient.isPlausiblePublicIPv4("198.20.1.1"))
    }
}
