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

    func testReplacingAllIncludesMatchesBeyondTheHighlightLimit() {
        let occurrences = CodeSearchEngine.maximumMatchCount + 37
        let text = String(repeating: "DOMAIN,example.com,DIRECT\n", count: occurrences)
        let query = CodeSearchQuery(text: "DOMAIN")

        XCTAssertEqual(CodeSearchEngine.matches(in: text, query: query).count, CodeSearchEngine.maximumMatchCount)

        let result = CodeSearchEngine.replacingAll(in: text, query: query, template: "DOMAIN-SUFFIX")

        XCTAssertEqual(result.count, occurrences)
        XCTAssertEqual(result.text, String(repeating: "DOMAIN-SUFFIX,example.com,DIRECT\n", count: occurrences))
    }

    func testLiteralReplacementPreservesUnicodeAndDoesNotExpandTemplates() {
        let text = "🌊中文 Example.example EXAMPLE"
        let result = CodeSearchEngine.replacingAll(
            in: text,
            query: CodeSearchQuery(text: "example"),
            template: #"$1\literal"#
        )

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.text, #"🌊中文 $1\literal.$1\literal $1\literal"#)

        let sensitive = CodeSearchEngine.replacingAll(
            in: text,
            query: CodeSearchQuery(text: "Example", isCaseSensitive: true),
            template: "changed"
        )
        XCTAssertEqual(sensitive.count, 1)
        XCTAssertEqual(sensitive.text, "🌊中文 changed.example EXAMPLE")
    }

    func testRegularExpressionReplacementIncludesEveryCaptureBeyondTheHighlightLimit() {
        let occurrences = CodeSearchEngine.maximumMatchCount + 37
        let text = String(repeating: "🌊 example.org\n", count: occurrences)
        let result = CodeSearchEngine.replacingAll(
            in: text,
            query: CodeSearchQuery(text: #"(example)\.org"#, usesRegularExpression: true),
            template: #"$1.net\$literal"#
        )

        XCTAssertEqual(result.count, occurrences)
        XCTAssertEqual(result.text, String(repeating: "🌊 example.net$literal\n", count: occurrences))
    }

    func testRegularExpressionReplacementPreservesZeroWidthMatchesAndLookarounds() {
        let lines = CodeSearchEngine.replacingAll(
            in: "🌊ab\n中文",
            query: CodeSearchQuery(text: #"(?m)^|$"#, usesRegularExpression: true),
            template: "|"
        )
        XCTAssertEqual(lines.text, "|🌊ab|\n|中文|")
        XCTAssertEqual(lines.count, 4)

        let lookaround = CodeSearchEngine.replacingAll(
            in: "🌊 prefix:Example.org:suffix",
            query: CodeSearchQuery(text: #"(?<=prefix:)([A-Za-z]+)\.org(?=:suffix)"#, usesRegularExpression: true),
            template: "$1.net"
        )
        XCTAssertEqual(lookaround.text, "🌊 prefix:Example.net:suffix")
        XCTAssertEqual(lookaround.count, 1)
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

    func testSingleRegularExpressionReplacementKeepsLookaroundContext() {
        let text = "🌊 prefix:Example.org:suffix"
        let query = CodeSearchQuery(
            text: #"(?<=prefix:)([A-Za-z]+)\.org(?=:suffix)"#,
            usesRegularExpression: true
        )
        let matches = CodeSearchEngine.matches(in: text, query: query)
        XCTAssertEqual(matches.count, 1)
        guard let match = matches.first else { return }

        XCTAssertEqual(
            CodeSearchEngine.replacement(for: match, in: text, query: query, template: "$1.net"),
            "Example.net"
        )
    }

    func testSingleRegularExpressionReplacementDoesNotAnchorAtTheSelectionBounds() {
        let text = "abc def"
        let query = CodeSearchQuery(text: #"(abc)$|(\w+)"#, usesRegularExpression: true)
        let matches = CodeSearchEngine.matches(in: text, query: query)
        guard let match = matches.first else { return XCTFail("Expected the first word to match") }

        XCTAssertEqual(
            CodeSearchEngine.replacement(for: match, in: text, query: query, template: "<$1:$2>"),
            "<:abc>"
        )
    }

    func testCancelledSearchReturnsNoPartialMatches() async {
        for usesRegularExpression in [false, true] {
            let task = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                return CodeSearchEngine.matches(
                    in: "example example example",
                    query: CodeSearchQuery(text: "example", usesRegularExpression: usesRegularExpression)
                )
            }
            let matches = await task.value
            XCTAssertTrue(matches.isEmpty)
        }
    }

    func testCancelledReplacementPreservesOriginalText() async {
        let text = "example example example"
        for usesRegularExpression in [false, true] {
            let task = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                return CodeSearchEngine.replacingAll(
                    in: text,
                    query: CodeSearchQuery(text: "example", usesRegularExpression: usesRegularExpression),
                    template: "replacement"
                )
            }
            let result = await task.value
            XCTAssertEqual(result.text, text)
            XCTAssertEqual(result.count, 0)
        }
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
