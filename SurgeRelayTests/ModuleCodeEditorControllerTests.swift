import AppKit
import XCTest
@testable import SurgeRelay

@MainActor
final class ModuleCodeEditorControllerTests: XCTestCase {
    func testTypingSearchOnlyPublishesLatestQuery() async throws {
        let (controller, textView) = makeEditor("old old target")
        controller.isFindBarPresented = true
        controller.findText = "old"
        controller.refreshMatches()
        controller.findText = "target"
        controller.refreshMatches()
        try await waitForSearch(controller)
        XCTAssertEqual(controller.matchCount, 1)
        controller.find(forward: true)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 8, length: 6))
    }

    func testReloadDiscardsPendingResults() async throws {
        let (controller, textView) = makeEditor("target target")
        controller.isFindBarPresented = true
        controller.findText = "target"
        controller.refreshMatches()
        textView.string = "updated target"
        controller.resetForReloadedContent()
        try await waitForSearch(controller)
        XCTAssertEqual(controller.matchCount, 1)
        controller.find(forward: true)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 8, length: 6))
    }

    func testFindCommandUsesCurrentQueryAndKeepsNavigation() async throws {
        let (controller, textView) = makeEditor("one two two")
        controller.isFindBarPresented = true
        controller.findText = "one"
        controller.refreshMatches()
        controller.findText = "two"
        controller.find(forward: true)
        try await waitForSearch(controller)
        XCTAssertFalse(controller.isSearching)
        XCTAssertEqual(controller.matchCount, 2)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 3))
        controller.find(forward: true)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 8, length: 3))
        XCTAssertEqual(controller.currentMatchNumber, 2)
    }

    func testReturningToPreviousQueryDoesNotReuseClearedResults() async throws {
        let (controller, textView) = makeEditor("alpha beta alpha")
        controller.isFindBarPresented = true
        controller.findText = "alpha"
        controller.refreshMatches(immediately: true)
        try await waitForSearch(controller)
        controller.findText = "beta"
        controller.refreshMatches()
        controller.findText = "alpha"
        controller.refreshMatches()
        try await waitForSearch(controller)
        XCTAssertEqual(controller.matchCount, 2)
        XCTAssertEqual(textView.string, "alpha beta alpha")
    }

    func testDismissedSearchCannotRestoreHighlightsOrCounts() async throws {
        let (controller, textView) = makeEditor("match match")
        controller.isFindBarPresented = true
        controller.findText = "match"
        controller.refreshMatches()
        controller.dismissFindBar()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(controller.isSearching)
        XCTAssertEqual(controller.matchCount, 0)
        XCTAssertNil(textView.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil))
    }

    func testCursorPositionUsesLogicalLinesAndGraphemeColumns() {
        let (_, textView) = makeEditor("first\n中文😀e\u{301}\nlast")
        textView.setSelectedRange(NSRange(location: ("first\n中文😀e\u{301}" as NSString).length, length: 0))
        XCTAssertEqual(textView.cursorPosition, ModuleCodeCursorPosition(line: 2, column: 5))
        textView.string = "short\nnew"
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        XCTAssertEqual(textView.cursorPosition, ModuleCodeCursorPosition(line: 2, column: 3))
    }

    func testCanonicallyEquivalentReloadInvalidatesUTF16LineOffsets() {
        let (_, textView) = makeEditor("e\u{301}\nx")
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertEqual(textView.cursorPosition, ModuleCodeCursorPosition(line: 2, column: 1))
        textView.string = "é\nx"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertEqual(textView.cursorPosition, ModuleCodeCursorPosition(line: 2, column: 1))
    }

    func testPathologicalRegexFindCommandCanBeCancelled() async throws {
        let (controller, textView) = makeEditor(String(repeating: "a", count: 100_000))
        controller.findText = "(a+)+b"
        controller.usesRegularExpression = true
        controller.find(forward: true)
        XCTAssertTrue(controller.isSearching)
        try await Task.sleep(for: .milliseconds(20))
        controller.findText = "a"
        controller.refreshMatches()
        try await waitForSearch(controller)
        XCTAssertEqual(controller.matchCount, CodeSearchEngine.maximumMatchCount)
        XCTAssertEqual(textView.selectedRange().length, 0)
    }

    func testPendingReplaceAllCannotOverwriteNewContent() async throws {
        let (controller, textView) = makeEditor(String(repeating: "a", count: 100_000))
        controller.findText = "(a+)+b"
        controller.usesRegularExpression = true
        controller.replacementText = "replacement"
        controller.replaceAll()
        XCTAssertTrue(controller.isReplacingAll)
        try await Task.sleep(for: .milliseconds(20))
        textView.string = "new manual content"
        controller.resetForReloadedContent()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(controller.isReplacingAll)
        XCTAssertEqual(textView.string, "new manual content")
    }

    func testReplaceAllAppliesEveryMatchInBackground() async throws {
        let (controller, textView) = makeEditor(String(repeating: "source ", count: 5_037))
        controller.findText = "source"
        controller.replacementText = "target"
        controller.replaceAll()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while controller.isReplacingAll, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(controller.isReplacingAll)
        XCTAssertEqual(textView.string, String(repeating: "target ", count: 5_037))
        XCTAssertEqual(controller.replaceAllSummary, "已替换 5037 处")
    }

    func testLongDocumentGutterOnlyAllocatesVisibleViewport() async throws {
        let (controller, textView) = makeEditor(String(repeating: "DOMAIN,example.org,DIRECT\n", count: 12_000))
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        scrollView.hasVerticalScroller = true
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        defer { window.close() }
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setFrameSize(NSSize(width: 640, height: 210_000))
        scrollView.documentView = textView
        textView.layoutSubtreeIfNeeded()
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 40_000))
        textView.refreshGutter()
        XCTAssertNotNil(textView.enclosingScrollView)
        let gutter = try XCTUnwrap(textView.subviews.first { $0 is GutterView })
        let viewport = textView.convert(scrollView.contentView.bounds, from: scrollView.contentView).intersection(textView.bounds)
        XCTAssertEqual(gutter.frame.minY, viewport.minY, accuracy: 0.5)
        XCTAssertLessThanOrEqual(gutter.frame.height, scrollView.contentView.bounds.height)
        let contents = try XCTUnwrap(gutter.layer?.contents)
        let bitmap = contents as! CGImage
        XCTAssertLessThanOrEqual(bitmap.height, 640)
        controller.updateViewport(NSRect(x: 0, y: 80_000, width: 623, height: 300))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(gutter.frame.minY, 80_000, accuracy: 0.5)
        XCTAssertEqual(gutter.frame.height, 300, accuracy: 0.5)
    }

    func testWidthMeasurementPreservesLiveFrameAndSelection() throws {
        let (_, textView) = makeEditor(String(repeating: "wrapped words ", count: 600))
        textView.setSelectedRange(NSRange(location: 25, length: 7))
        let frame = textView.frame
        let selection = textView.selectedRange()
        let wide = try XCTUnwrap(textView.measuredContentSize(forWidth: 640))
        let narrow = try XCTUnwrap(textView.measuredContentSize(forWidth: 220))
        XCTAssertGreaterThan(narrow.height, wide.height)
        XCTAssertEqual(textView.measuredContentSize(forWidth: 640), wide)
        XCTAssertEqual(textView.frame, frame)
        XCTAssertEqual(textView.selectedRange(), selection)
        textView.string = "short"
        let updated = try XCTUnwrap(textView.measuredContentSize(forWidth: 640))
        XCTAssertLessThan(updated.height, wide.height)
        XCTAssertEqual(textView.frame, frame)
    }

    private func makeEditor(_ text: String) -> (ModuleCodeEditorController, CodeTextView) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 320), textContainer: container)
        textView.string = text
        textView.isEditable = true
        let controller = ModuleCodeEditorController()
        controller.attach(textView)
        controller.setEditable(true)
        return (controller, textView)
    }

    private func waitForSearch(_ controller: ModuleCodeEditorController) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while controller.isSearching, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(controller.isSearching, "Search did not finish")
    }
}
