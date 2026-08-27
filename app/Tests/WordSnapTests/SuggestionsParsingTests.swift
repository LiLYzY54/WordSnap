import XCTest
@testable import WordSnap

final class SuggestionsParsingTests: XCTestCase {

    private static let fixture = """
    {"result":"success","data":{"entries":[
        {"entry":"serendipitous","explain":"adj."},
        {"entry":"Serendipity","explain":"n."},
        {"entry":""},
        {"entry":"serenity","explain":"n."}
    ]}}
    """

    func testParsesAndExcludesQueriedWord() {
        let suggestions = WordService.parseSuggestions(
            Data(Self.fixture.utf8), excluding: "serendipity")
        XCTAssertEqual(suggestions, ["serendipitous", "serenity"],
                       "排除查询词本身（大小写不敏感）、过滤空项、上限 4")
    }

    func testMalformedJSONYieldsEmpty() {
        XCTAssertTrue(WordService.parseSuggestions(Data("junk".utf8), excluding: "x").isEmpty)
    }
}
