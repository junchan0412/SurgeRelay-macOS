import XCTest
@testable import SurgeRelay

final class CodeSearchEngineTests: XCTestCase {
    private let sample = """
    #!name=Demo
    [Rule]
    DOMAIN,example.com,DIRECT
    DOMAIN,Example.org,PROXY
    """

    func testLiteralSearchIsCaseInsensitiveByDefault() {
        let matches = CodeSearchEngine.matches(
            in: sample,
            query: CodeSearchQuery(text: "example")
        )

        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual((sample as NSString).substring(with: matches[0]), "example")
        XCTAssertEqual((sample as NSString).substring(with: matches[1]), "Example")
    }

    func testCaseSensitiveSearchNarrowsResults() {
        let matches = CodeSearchEngine.matches(
            in: sample,
            query: CodeSearchQuery(text: "Example", isCaseSensitive: true)
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual((sample as NSString).substring(with: matches[0]), "Example")
    }

    func testEmptyQueryAndEmptyTextProduceNoMatches() {
        XCTAssertTrue(CodeSearchEngine.matches(in: sample, query: CodeSearchQuery(text: "")).isEmpty)
        XCTAssertTrue(CodeSearchEngine.matches(in: "", query: CodeSearchQuery(text: "a")).isEmpty)
    }

    func testSearchWorksOnUTF16OffsetsWithMultibyteText() {
        let text = "网络模块 example 模块 example"
        let matches = CodeSearchEngine.matches(in: text, query: CodeSearchQuery(text: "example"))

        XCTAssertEqual(matches.count, 2)
        for match in matches {
            XCTAssertEqual((text as NSString).substring(with: match), "example")
        }
    }

    func testRegularExpressionSearchAndInvalidPatternReporting() {
        let matches = CodeSearchEngine.matches(
            in: sample,
            query: CodeSearchQuery(text: #"DOMAIN,([^,]+),"#, usesRegularExpression: true)
        )
        XCTAssertEqual(matches.count, 2)

        let invalid = CodeSearchQuery(text: "([", usesRegularExpression: true)
        XCTAssertTrue(CodeSearchEngine.matches(in: sample, query: invalid).isEmpty)
        XCTAssertEqual(
            CodeSearchEngine.regularExpressionErrorMessage(for: invalid),
            "正则表达式无效"
        )
        XCTAssertNil(CodeSearchEngine.regularExpressionErrorMessage(for: CodeSearchQuery(text: "([")))
    }

    func testAdjacentMatchIndexWrapsAroundInBothDirections() {
        let matches = [
            NSRange(location: 10, length: 3),
            NSRange(location: 30, length: 3),
            NSRange(location: 50, length: 3),
        ]

        XCTAssertEqual(
            CodeSearchEngine.adjacentMatchIndex(
                in: matches,
                from: NSRange(location: 0, length: 0),
                forward: true
            ),
            0
        )
        XCTAssertEqual(
            CodeSearchEngine.adjacentMatchIndex(in: matches, from: matches[0], forward: true),
            1
        )
        XCTAssertEqual(
            CodeSearchEngine.adjacentMatchIndex(in: matches, from: matches[2], forward: true),
            0
        )
        XCTAssertEqual(
            CodeSearchEngine.adjacentMatchIndex(in: matches, from: matches[1], forward: false),
            0
        )
        XCTAssertEqual(
            CodeSearchEngine.adjacentMatchIndex(
                in: matches,
                from: NSRange(location: 0, length: 0),
                forward: false
            ),
            2
        )
        XCTAssertNil(
            CodeSearchEngine.adjacentMatchIndex(
                in: [],
                from: NSRange(location: 0, length: 0),
                forward: true
            )
        )
    }

    func testMatchIndexTracksTheCurrentSelection() {
        let matches = [NSRange(location: 4, length: 2), NSRange(location: 9, length: 2)]

        XCTAssertEqual(CodeSearchEngine.matchIndex(in: matches, equalTo: matches[1]), 1)
        XCTAssertNil(
            CodeSearchEngine.matchIndex(in: matches, equalTo: NSRange(location: 5, length: 2))
        )
    }

    func testReplacingAllRewritesEveryMatchOnce() {
        let result = CodeSearchEngine.replacingAll(
            in: sample,
            query: CodeSearchQuery(text: "DOMAIN"),
            template: "DOMAIN-SUFFIX"
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(
            result.text,
            """
            #!name=Demo
            [Rule]
            DOMAIN-SUFFIX,example.com,DIRECT
            DOMAIN-SUFFIX,Example.org,PROXY
            """
        )
    }

    func testReplacingAllSupportsRegularExpressionTemplates() {
        let result = CodeSearchEngine.replacingAll(
            in: sample,
            query: CodeSearchQuery(text: #"DOMAIN,([^,]+),(\w+)"#, usesRegularExpression: true),
            template: "DOMAIN,$1,DIRECT"
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.text.contains("DOMAIN,Example.org,DIRECT"))
        XCTAssertFalse(result.text.contains("PROXY"))
    }

    func testReplacementForASingleRegularExpressionMatchExpandsCaptureGroups() {
        let match = CodeSearchEngine.matches(
            in: sample,
            query: CodeSearchQuery(text: #"DOMAIN,([^,]+),(\w+)"#, usesRegularExpression: true)
        )[1]

        XCTAssertEqual(
            CodeSearchEngine.replacement(
                for: match,
                in: sample,
                query: CodeSearchQuery(text: #"DOMAIN,([^,]+),(\w+)"#, usesRegularExpression: true),
                template: "DOMAIN-SUFFIX,$1,$2"
            ),
            "DOMAIN-SUFFIX,Example.org,PROXY"
        )
        XCTAssertEqual(
            CodeSearchEngine.replacement(
                for: match,
                in: sample,
                query: CodeSearchQuery(text: "DOMAIN"),
                template: "literal"
            ),
            "literal"
        )
    }

    func testReplacingAllWithoutMatchesKeepsTheOriginalText() {
        let result = CodeSearchEngine.replacingAll(
            in: sample,
            query: CodeSearchQuery(text: "missing"),
            template: "x"
        )

        XCTAssertEqual(result.count, 0)
        XCTAssertEqual(result.text, sample)
    }

    func testMatchSummaryReportsPositionAndTotal() {
        XCTAssertEqual(CodeSearchEngine.matchSummary(matchCount: 0, currentNumber: nil), "无结果")
        XCTAssertEqual(CodeSearchEngine.matchSummary(matchCount: 4, currentNumber: nil), "4 个结果")
        XCTAssertEqual(CodeSearchEngine.matchSummary(matchCount: 4, currentNumber: 2), "第 2 / 4 个")
    }
}
