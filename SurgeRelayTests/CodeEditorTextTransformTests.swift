import XCTest
@testable import SurgeRelay

final class CodeEditorTextTransformTests: XCTestCase {
    func testIndentInsertsTheUnitAtACollapsedCursor() {
        let edit = CodeEditorTextTransform.indent(
            in: "[Rule]\nFINAL,DIRECT",
            selection: NSRange(location: 7, length: 0)
        )

        XCTAssertEqual(edit.range, NSRange(location: 7, length: 0))
        XCTAssertEqual(edit.replacement, "    ")
        XCTAssertEqual(edit.selection, NSRange(location: 11, length: 0))
    }

    func testIndentPrefixesEverySelectedNonEmptyLine() {
        let text = "a\n\nb\n"
        let edit = CodeEditorTextTransform.indent(
            in: text,
            selection: NSRange(location: 0, length: 4)
        )

        XCTAssertEqual(edit.replacement, "    a\n\n    b\n")
        XCTAssertEqual(edit.range, NSRange(location: 0, length: 5))
        XCTAssertEqual(edit.selection.location, 0)
    }

    func testUnindentRemovesOneLevelAndReportsNoChange() {
        let text = "    a\n\tb\n c\nd\n"
        let edit = CodeEditorTextTransform.unindent(
            in: text,
            selection: NSRange(location: 0, length: (text as NSString).length)
        )

        XCTAssertEqual(edit?.replacement, "a\nb\nc\nd\n")
        XCTAssertNil(CodeEditorTextTransform.unindent(
            in: "abc",
            selection: NSRange(location: 0, length: 3)
        ))
    }

    func testNewlineKeepsTheCurrentIndentation() {
        let text = "        DOMAIN,example.com,DIRECT"
        let edit = CodeEditorTextTransform.newlineKeepingIndentation(
            in: text,
            selection: NSRange(location: (text as NSString).length, length: 0)
        )

        XCTAssertEqual(edit.replacement, "\n        ")
        XCTAssertEqual(edit.selection.length, 0)
        XCTAssertEqual(edit.selection.location, (text as NSString).length + 9)
    }

    func testToggleCommentAddsMarkersAtTheSharedIndentation() {
        let text = "    DOMAIN,a,DIRECT\n        DOMAIN,b,DIRECT\n"
        let edit = CodeEditorTextTransform.toggleComment(
            in: text,
            selection: NSRange(location: 0, length: (text as NSString).length)
        )

        XCTAssertEqual(
            edit?.replacement,
            "    # DOMAIN,a,DIRECT\n    #     DOMAIN,b,DIRECT\n"
        )
    }

    func testToggleCommentRemovesMarkersWhenEveryLineIsCommented() {
        let text = "# DOMAIN,a,DIRECT\n  #DOMAIN,b,DIRECT\n"
        let edit = CodeEditorTextTransform.toggleComment(
            in: text,
            selection: NSRange(location: 0, length: (text as NSString).length)
        )

        XCTAssertEqual(edit?.replacement, "DOMAIN,a,DIRECT\n  DOMAIN,b,DIRECT\n")
    }

    func testToggleCommentIgnoresBlankSelectionsAndEmptyText() {
        XCTAssertNil(CodeEditorTextTransform.toggleComment(
            in: "\n\n",
            selection: NSRange(location: 0, length: 2)
        ))
        XCTAssertNil(CodeEditorTextTransform.toggleComment(
            in: "",
            selection: NSRange(location: 0, length: 0)
        ))
    }

    func testToggleCommentKeepsACollapsedCursorOnTheSameLine() {
        let text = "DOMAIN,a,DIRECT\n"
        let edit = CodeEditorTextTransform.toggleComment(
            in: text,
            selection: NSRange(location: 6, length: 0)
        )

        XCTAssertEqual(edit?.replacement, "# DOMAIN,a,DIRECT\n")
        XCTAssertEqual(edit?.selection, NSRange(location: 8, length: 0))
    }

    func testLineRangeAndLineCount() {
        let text = "one\ntwo\nthree"

        XCTAssertEqual(CodeEditorTextTransform.lineCount(in: text), 3)
        XCTAssertEqual(
            CodeEditorTextTransform.range(in: text, forLine: 2),
            NSRange(location: 4, length: 3)
        )
        XCTAssertEqual(
            CodeEditorTextTransform.range(in: text, forLine: 3),
            NSRange(location: 8, length: 5)
        )
        XCTAssertNil(CodeEditorTextTransform.range(in: text, forLine: 4))
        XCTAssertNil(CodeEditorTextTransform.range(in: text, forLine: 0))
        XCTAssertEqual(CodeEditorTextTransform.lineCount(in: ""), 1)
        XCTAssertEqual(
            CodeEditorTextTransform.range(in: "", forLine: 1),
            NSRange(location: 0, length: 0)
        )
    }

    func testLineRangeExcludesTheLineTerminator() {
        let text = "alpha\r\nbeta\n"

        XCTAssertEqual(
            CodeEditorTextTransform.range(in: text, forLine: 1),
            NSRange(location: 0, length: 5)
        )
        XCTAssertEqual(
            CodeEditorTextTransform.range(in: text, forLine: 2),
            NSRange(location: 7, length: 4)
        )
    }
}
