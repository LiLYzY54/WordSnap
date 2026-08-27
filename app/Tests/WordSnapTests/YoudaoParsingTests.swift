import XCTest
@testable import WordSnap

final class YoudaoParsingTests: XCTestCase {

    // MARK: - Fixtures（有道 jsonapi 各字段形态的最小还原）

    private static let collinsJSON = """
    {
      "simple": {"word": [{"usphone": "ɪˈfemərəl"}]},
      "collins": {"collins_entries": [{"entries": {"entry": [
        {"star": "4",
         "tran_entry": [
          {"tran": "Something that is ephemeral lasts for only a very short time. 短暂的；朝生暮死的",
           "pos_entry": {"pos_tips": "ADJ"}}
        ]}
      ]}}]},
      "blng_sents_part": {"sentence-pair": [
        {"sentence": "Fame in the world of rock and roll is largely <b>ephemeral</b>."}
      ]}
    }
    """

    private static let ecJSON = """
    {
      "ec": {"word": [{"trs": [
        {"tr": [{"l": {"i": ["adj. <span>短暂的</span>", "n. 蜉蝣"]}}]}
      ]}]},
      "simple": {"custom": []}
    }
    """

    private func parse(_ json: String, word: String = "ephemeral") throws -> WordEntry {
        try WordService.parse(Data(json.utf8), word: word)
    }

    // MARK: - 柯林斯路径：词性 + 英文释义 + 中文释义拆分

    func testCollinsPathSplitsEnglishAndChinese() throws {
        let entry = try parse(Self.collinsJSON)
        XCTAssertEqual(entry.partOfSpeech, "ADJ")
        XCTAssertEqual(entry.englishDef,
                       "Something that is ephemeral lasts for only a very short time.")
        XCTAssertEqual(entry.meaning, "短暂的；朝生暮死的")
        XCTAssertEqual(entry.phonetic, "ɪˈfemərəl")
        XCTAssertEqual(entry.star, "4", "柯林斯星级应被解码")
        XCTAssertFalse(entry.example.contains("<b>"), "HTML 标签应被清理")
        XCTAssertTrue(entry.example.contains("ephemeral"))
        XCTAssertEqual(entry.source, "Youdao")
    }

    // MARK: - ec 词典兜底：无柯林斯时拼接 trs，英文释义为空

    func testECFallbackJoinsTranslationsAndStripsTags() throws {
        let entry = try parse(Self.ecJSON)
        XCTAssertEqual(entry.meaning, "adj. 短暂的; n. 蜉蝣")
        XCTAssertEqual(entry.englishDef, "")
        XCTAssertEqual(entry.partOfSpeech, "")
    }

    // MARK: - 查无此词：响应有效但没有任何释义 → notFound（而非 badResponse）

    func testEmptyMeaningThrowsNotFound() {
        let emptyResponse = #"{"simple": {"word": []}}"#
        XCTAssertThrowsError(try parse(emptyResponse)) { error in
            guard case .notFound(let candidates) = error as! LookupError else {
                return XCTFail("expected notFound, got \(error)")
            }
            XCTAssertTrue(candidates.isEmpty, "解析层抛出的 notFound 不带候选")
        }
    }

    func testMalformedJSONThrowsBadResponse() {
        XCTAssertThrowsError(try parse("not json at all")) { error in
            guard case LookupError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
    }

    // MARK: - 中英拆分

    func testSplitEnglishChinese() {
        let (en, zh) = WordService.splitEnglishChinese("If you do X, you Y 如果你做某事，你就……")
        XCTAssertEqual(en, "If you do X, you Y")
        XCTAssertEqual(zh, "如果你做某事，你就……")

        // 纯中文（开头即是 CJK）：英文侧为空
        let (en2, zh2) = WordService.splitEnglishChinese("只有中文")
        XCTAssertEqual(en2, "")
        XCTAssertEqual(zh2, "只有中文")
    }

    // MARK: - 状态行解析（直连客户端）

    func testStatusCodeParsing() {
        XCTAssertEqual(WordService.YoudaoDirectClient.statusCode(
            in: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"), 200)
        XCTAssertEqual(WordService.YoudaoDirectClient.statusCode(
            in: "HTTP/1.0 403 Forbidden\r\n\r\n"), 403)
        XCTAssertNil(WordService.YoudaoDirectClient.statusCode(in: "garbage"))
    }
}
