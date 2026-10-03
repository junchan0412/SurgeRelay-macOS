import AppKit
import XCTest
import SwiftUI
@testable import SurgeRelay

@MainActor
final class ModuleCodeEditorControllerTests: XCTestCase {
    func testTextBindingUsesContiguousUTF8WithoutNormalizingUnicode() {
        let decomposed = "e\u{301}"
        let composed = "\u{e9}"
        let suffix = String(repeating: "中文 👩🏽‍💻 \r\n", count: 4_096)
        var bound = ""
        let coordinator = ModuleCodeTextView.Coordinator(
            text: Binding(get: { bound }, set: { bound = $0 }), controller: nil, onCursorPositionChange: nil)
        let (_, textView) = makeEditor("")
        coordinator.textView = textView
        let first = decomposed + suffix
        textView.string = NSMutableString(string: first) as String
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        XCTAssertTrue(bound.isContiguousUTF8)
        XCTAssertTrue(bound.utf8.elementsEqual(first.utf8))
        XCTAssertTrue(bound.utf16.elementsEqual(first.utf16))
        let captured = bound
        let second = composed + suffix
        textView.string = NSMutableString(string: second) as String
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        XCTAssertTrue(bound.isContiguousUTF8)
        XCTAssertTrue(bound.utf8.elementsEqual(second.utf8))
        XCTAssertEqual(captured, bound)
        XCTAssertFalse(captured.utf16.elementsEqual(bound.utf16))
        XCTAssertTrue(captured.utf8.elementsEqual(first.utf8))
    }

    func testNativeTextSnapshotInvalidatesOnTypingUndoAndExternalReload() throws {
        let (_, textView) = makeEditor("")
        textView.isEditable = true
        textView.allowsUndo = true
        let coordinator = ModuleCodeTextView.Coordinator(text: .constant(""), controller: nil, onCursorPositionChange: nil)
        coordinator.textView = textView
        textView.delegate = coordinator
        textView.string = "e\u{301} 中文"
        let first = textView.nativeTextSnapshot
        XCTAssertTrue(first.isContiguousUTF8)
        XCTAssertTrue(first.utf8.elementsEqual(textView.nativeTextSnapshot.utf8))
        let storage = try XCTUnwrap(textView.textStorage)
        XCTAssertNotNil(textView.layoutManager)
        textView.undoManager?.beginUndoGrouping()
        textView.insertText("!", replacementRange: NSRange(location: storage.length, length: 0))
        textView.undoManager?.endUndoGrouping()
        XCTAssertEqual(textView.nativeTextSnapshot, first + "!")
        XCTAssertTrue(textView.undoManager?.canUndo == true)
        textView.undoManager?.undo()
        XCTAssertTrue(textView.nativeTextSnapshot.utf8.elementsEqual(first.utf8))
        textView.string = "external 👩🏽‍💻\r\n"
        XCTAssertTrue(textView.nativeTextSnapshot.utf8.elementsEqual("external 👩🏽‍💻\r\n".utf8))
        XCTAssertTrue(first.utf8.elementsEqual("e\u{301} 中文".utf8))
    }

    func testSharedLineScanMatchesNSStringNewlinesTabsAndTrailingLines() {
        let separators = ["\n", "\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}", "\u{0B}", "\u{0C}"]
        var fixtures = ["", "a", "\t", "a\tb\t", "👩🏽‍💻e\u{301}中文", "a\r\n\r\nb\n", "\r\r\n"]
        fixtures += separators.flatMap { ["a" + $0 + "b", "a" + $0, $0, "\t" + $0 + "👩🏽‍💻\t"] }
        for text in fixtures {
            let metrics = ModuleCodeLineMetrics(text: text)
            let source = text as NSString
            var expectedLines = 1
            var expectedWidth = 0
            var offset = 0
            while offset < source.length {
                var end = 0
                var contentsEnd = 0
                source.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: offset, length: 0))
                let line = source.substring(with: NSRange(location: offset, length: contentsEnd - offset))
                let tabs = line.utf16.filter { $0 == 0x09 }.count
                expectedWidth = max(expectedWidth, contentsEnd - offset + tabs * 3)
                if end > contentsEnd { expectedLines += 1 }
                offset = end
            }
            XCTAssertEqual(metrics.plainLineCount, expectedLines, String(reflecting: text))
            XCTAssertEqual(metrics.plainLongestLine, expectedWidth, String(reflecting: text))
        }
        let mixed = ModuleCodeLineMetrics(text: "a\r\nb\rc\u{85}d\u{2028}e\u{2029}f\n")
        XCTAssertEqual(mixed.gutterLineStarts, [0, 3, 13])
        XCTAssertEqual(mixed.plainLineCount, 7)
    }

    func testSharedLineScanKeepsGraphemeCursorColumnsAndInvalidatesAfterEdits() {
        let text = "α\n👩🏽‍💻e\u{301}"
        let (_, textView) = makeEditor(text)
        textView.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        XCTAssertEqual(textView.cursorPosition, ModuleCodeCursorPosition(line: 2, column: 3))
        XCTAssertEqual(textView.lineMetrics.gutterLineStarts, [0, 2])
        let before = textView.lineMetrics.plainLongestLine
        XCTAssertTrue(textView.applyEdit(CodeEditorEdit(range: NSRange(location: text.utf16.count, length: 0),
            replacement: "\t\r\n", selection: NSRange(location: text.utf16.count + 3, length: 0))))
        XCTAssertEqual(textView.lineMetrics.plainLongestLine, before + 4)
        XCTAssertEqual(textView.lineMetrics.plainLineCount, 3)
        XCTAssertEqual(textView.cursorPosition, ModuleCodeCursorPosition(line: 3, column: 1))
        textView.string = "tail\r"
        XCTAssertEqual(textView.lineMetrics.plainLineCount, 2)
        XCTAssertEqual(textView.lineMetrics.gutterLineStarts, [0])
    }

    func testHighlightChangeDetectionKeepsExactUnicodeAtEqualUTF8Lengths() {
        let coordinator = ModuleCodeTextView.Coordinator(text: .constant(""), controller: nil, onCursorPositionChange: nil)
        XCTAssertTrue(coordinator.needsHighlight(text: "中文", selectedModuleID: nil))
        XCTAssertFalse(coordinator.needsHighlight(text: "中文", selectedModuleID: nil))
        XCTAssertTrue(coordinator.needsHighlight(text: "中文!", selectedModuleID: nil))
        XCTAssertTrue(coordinator.needsHighlight(text: "éx", selectedModuleID: nil))
        XCTAssertTrue(coordinator.needsHighlight(text: "e\u{301}", selectedModuleID: nil))
        XCTAssertFalse(coordinator.needsHighlight(text: "e\u{301}", selectedModuleID: nil))
    }

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

    func testSearchSummaryDistinguishesExactCapFromTruncation() async throws {
        let (controller, textView) = makeEditor(String(repeating: "match ", count: 5_000))
        controller.isFindBarPresented = true
        controller.findText = "match"
        controller.refreshMatches(immediately: true)
        try await waitForSearch(controller)
        XCTAssertEqual(controller.matchSummary, "5000 个结果")
        textView.string += "match"
        controller.resetForReloadedContent()
        try await waitForSearch(controller)
        XCTAssertEqual(controller.matchSummary, "5000+ 个结果（仅前 5000 个）")
    }

    func testPlainTextModeDoesNotPerformWidthDependentLayout() throws {
        let source = String(repeating: "DOMAIN,example.org,DIRECT\n", count: 12_000)
        let (_, textView) = makeEditor(source)
        XCTAssertTrue(textView.isPlainTextMode)
        let narrow = try XCTUnwrap(textView.measuredContentSize(forWidth: 200))
        let wide = try XCTUnwrap(textView.measuredContentSize(forWidth: 900))
        XCTAssertEqual(narrow.height, wide.height)
        XCTAssertEqual(wide.height, 12_001 * CodeTextView.plainTextLineHeight + textView.textContainerInset.height * 2)
        XCTAssertLessThan(textView.layoutManager?.firstUnlaidCharacterIndex() ?? Int.max, source.utf16.count)
        XCTAssertEqual(textView.string, source)
        let style = try XCTUnwrap(textView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.minimumLineHeight, CodeTextView.plainTextLineHeight)
        XCTAssertEqual(style.maximumLineHeight, CodeTextView.plainTextLineHeight)
        textView.string = "small"
        XCTAssertFalse(textView.isPlainTextMode)
        XCTAssertEqual(textView.textContainer?.lineBreakMode, .byWordWrapping)
    }

    func testPlainTextNaturalSizeSurvivesZeroAndNonfiniteProposals() throws {
        let (_, textView) = makeEditor(String(repeating: "DOMAIN,example.org,DIRECT\n", count: 12_000))
        textView.setFrameSize(.zero)
        XCTAssertTrue(textView.isPlainTextMode)
        let natural = try XCTUnwrap(textView.measuredContentSize(forWidth: 0))
        XCTAssertGreaterThan(natural.width, 0)
        XCTAssertEqual(natural.height, 12_001 * CodeTextView.plainTextLineHeight + textView.textContainerInset.height * 2)
        for width: CGFloat in [.infinity, -.infinity, .nan, -1] {
            let size = try XCTUnwrap(textView.measuredContentSize(forWidth: width))
            XCTAssertEqual(size, natural)
            XCTAssertTrue(size.width.isFinite)
            XCTAssertTrue(size.height.isFinite)
        }
        let wide = try XCTUnwrap(textView.measuredContentSize(forWidth: natural.width + 500))
        XCTAssertEqual(wide.width, natural.width + 500)
        XCTAssertEqual(wide.height, natural.height)
        XCTAssertEqual(textView.measuredContentSize(forWidth: 0), natural)
        textView.string = "short"
        XCTAssertFalse(textView.isPlainTextMode)
        XCTAssertNil(textView.measuredContentSize(forWidth: 0))
        XCTAssertNil(textView.measuredContentSize(forWidth: .infinity))
        XCTAssertNil(textView.measuredContentSize(forWidth: .nan))
        let wrapped = try XCTUnwrap(textView.measuredContentSize(forWidth: 640))
        XCTAssertLessThan(wrapped.height, natural.height)
    }

    func testLargeModeRetainsEditableTextAndUndo() throws {
        let (_, textView) = makeEditor(String(repeating: "line\n", count: 60_000))
        let coordinator = ModuleCodeTextView.Coordinator(text: .constant(textView.string), controller: nil, onCursorPositionChange: nil)
        coordinator.textView = textView
        textView.delegate = coordinator
        textView.allowsUndo = true
        let original = textView.string
        textView.undoManager?.beginUndoGrouping()
        XCTAssertTrue(textView.applyEdit(CodeEditorEdit(range: NSRange(location: 0, length: 4), replacement: "changed", selection: NSRange(location: 7, length: 0))))
        textView.undoManager?.endUndoGrouping()
        XCTAssertTrue(textView.isPlainTextMode)
        XCTAssertTrue(textView.undoManager?.canUndo == true)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, original)
    }

    func testSyntaxRangesUseUTF16AndDiscardCancelledWork() async {
        let source = "# 中文😀\n[Rule]\nhttps://example.org"
        let ranges = await Task.detached { ModuleCodeSyntaxRanges.compute(in: source) }.value
        XCTAssertEqual(ranges[0], [NSRange(location: 0, length: 6)])
        XCTAssertEqual(ranges[2], [NSRange(location: 7, length: 6)])
        let cancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return ModuleCodeSyntaxRanges.compute(in: source)
        }.value
        XCTAssertTrue(cancelled.allSatisfy(\.isEmpty))
    }

    func testDraftRoundTripRetainsBaselineAndExactUnicodeChanges() throws {
        let draft = ModulePreviewDraft(text: "unsaved edit", savedText: "e\u{301}")
        let encoded = try JSONEncoder().encode(draft)
        XCTAssertEqual(try JSONDecoder().decode(ModulePreviewDraft.self, from: encoded), draft)
        XCTAssertFalse(draft.hasBaseChanged(comparedTo: "e\u{301}"))
        XCTAssertTrue(draft.hasBaseChanged(comparedTo: "é"))
        XCTAssertTrue(draft.hasBaseChanged(comparedTo: "upstream change"))
    }

    func testEditorSizeAndSearchBenchmark() async throws {
        var samples: [[String: Double]] = []
        for size in [100 * 1024, 1024 * 1024, 5 * 1024 * 1024] {
            let line = "DOMAIN,example.org,DIRECT\n"
            let source = String(repeating: line, count: size / line.utf8.count)
            let (_, textView) = makeEditor(source)
            let start = ContinuousClock.now
            let measured = try XCTUnwrap(textView.measuredContentSize(forWidth: 640))
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let searchStart = ContinuousClock.now
            let result = await Task.detached {
                CodeSearchEngine.search(in: source, query: CodeSearchQuery(text: "example.org"))
            }.value
            let searchElapsed = searchStart.duration(to: .now)
            XCTAssertGreaterThan(measured.height, 0)
            XCTAssertEqual(result.ranges.count, min(size / line.utf8.count, 5_000))
            samples.append([
                "bytes": Double(source.utf8.count),
                "measurementSeconds": seconds,
                "searchSeconds": Double(searchElapsed.components.seconds) + Double(searchElapsed.components.attoseconds) / 1e18,
            ])
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "relay-editor-size-search-benchmark"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testOptInNativeEditorComponentMatrix() async throws {
        guard ProcessInfo.processInfo.environment["SURGE_RELAY_EDITOR_COMPONENT_MATRIX"] == "1" else {
            throw XCTSkip("Set SURGE_RELAY_EDITOR_COMPONENT_MATRIX=1 for the three-size component matrix")
        }
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        var samples: [[String: Any]] = []
        defer {
            let report: [String: Any] = [
                "boundary": "Explicit TextKit 1 CodeTextView + controller component calls; not real keyboard, SwiftUI tab UI, NSApplication.didUpdate, GPU presentation, or FPS",
                "configuration": configuration,
                "samplesPerOperation": 1,
                "asyncCompletionPollingMilliseconds": 5,
                "samples": samples,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "native-editor-component-matrix"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        for size in [100 * 1024, 1024 * 1024, 5 * 1024 * 1024] {
            let prefix = "  marker_0001 value\n  marker_0002 value\n"
            let line = "DOMAIN,example.org,DIRECT\n"
            let lineCount = (size - prefix.utf8.count) / line.utf8.count
            let paddingCount = size - prefix.utf8.count - lineCount * line.utf8.count
            let source = prefix + String(repeating: line, count: lineCount) + String(repeating: "#", count: paddingCount)
            XCTAssertEqual(source.utf8.count, size)
            let (controller, textView) = makeEditor(source)
            XCTAssertNotNil(textView.layoutManager)
            XCTAssertNil(textView.textLayoutManager, "The fixture must remain explicit TextKit 1")
            var boundText = source
            let coordinator = ModuleCodeTextView.Coordinator(
                text: Binding(get: { boundText }, set: { boundText = $0 }), controller: controller, onCursorPositionChange: nil)
            coordinator.textView = textView
            textView.delegate = coordinator
            textView.allowsUndo = true
            let undo = try XCTUnwrap(textView.undoManager)
            undo.groupsByEvent = false
            var timings: [String: Double] = [:]
            let sampleIndex = samples.count
            samples.append([
                "bytes": size,
                "utf16Characters": source.utf16.count,
                "plainTextMode": textView.isPlainTextMode,
                "completed": false,
                "fullDocumentLayoutMeasurementCount": NSNull(),
                "layoutCountNote": "measurementFullDocumentLayoutRequests/Completions count only the fresh temporary layout manager used for size measurement. No whole-application/live TextKit full-pass count is available.",
                "paneLifecycleBoundary": "dismissFindBar and resetForReloadedContent on retained components, not a SwiftUI tab interaction",
            ])
            defer {
                samples[sampleIndex]["seconds"] = timings
                controller.dismissFindBar()
                textView.delegate = nil
            }

            controller.isFindBarPresented = true
            controller.findText = "example.org"
            var start = ContinuousClock.now
            controller.refreshMatches(immediately: true)
            try await waitForMatrixCompletion(controller)
            timings["plainSearchCompletion"] = matrixSeconds(since: start)
            XCTAssertEqual(controller.matchCount, min(lineCount, CodeSearchEngine.maximumMatchCount))
            XCTAssertEqual(controller.matchesAreTruncated, lineCount > CodeSearchEngine.maximumMatchCount)

            controller.usesRegularExpression = true
            controller.findText = #"marker_(000[12])"#
            start = .now
            controller.refreshMatches(immediately: true)
            try await waitForMatrixCompletion(controller)
            timings["regexSearchCompletion"] = matrixSeconds(since: start)
            XCTAssertEqual(controller.matchCount, 2)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            controller.find(forward: true)
            XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 11))
            controller.replacementText = "renamed_$1"
            let oneReplacement = source.replacingOccurrences(of: "marker_0001", with: "renamed_0001")
            undo.beginUndoGrouping()
            start = .now
            controller.replaceCurrent()
            timings["regexReplaceCurrentCall"] = matrixSeconds(since: start)
            undo.endUndoGrouping()
            try await waitForMatrixCompletion(controller)
            XCTAssertTrue(textView.string.utf8.elementsEqual(oneReplacement.utf8), "Regex capture replacement must update the actual text")
            XCTAssertTrue(boundText.utf8.elementsEqual(oneReplacement.utf8))
            XCTAssertTrue(undo.canUndo)
            start = .now
            controller.undo()
            timings["regexReplacementUndoCall"] = matrixSeconds(since: start)
            try await waitForMatrixCompletion(controller)
            XCTAssertTrue(textView.string.utf8.elementsEqual(source.utf8))

            controller.usesRegularExpression = false
            controller.findText = "example.org"
            controller.replacementText = "changed.org"
            let allReplaced = source.replacingOccurrences(of: "example.org", with: "changed.org")
            undo.beginUndoGrouping()
            start = .now
            controller.replaceAll()
            try await waitForMatrixCompletion(controller)
            timings["replaceAllCompletionIncludingSearchRefresh"] = matrixSeconds(since: start)
            undo.endUndoGrouping()
            XCTAssertEqual(controller.replaceAllSummary, "已替换 \(lineCount) 处")
            XCTAssertTrue(textView.string.utf8.elementsEqual(allReplaced.utf8), "Replace-all must exceed the search display cap when needed")
            XCTAssertTrue(undo.canUndo)
            start = .now
            controller.undo()
            timings["replaceAllUndoCall"] = matrixSeconds(since: start)
            try await waitForMatrixCompletion(controller)
            XCTAssertTrue(textView.string.utf8.elementsEqual(source.utf8))

            controller.dismissFindBar()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            undo.beginUndoGrouping()
            start = .now
            let handledTab = coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:)))
            timings["tabDelegateCommand"] = matrixSeconds(since: start)
            XCTAssertTrue(handledTab)
            undo.endUndoGrouping()
            XCTAssertTrue(textView.string.utf8.elementsEqual(("    " + source).utf8))
            XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 0))
            controller.undo()
            XCTAssertTrue(textView.string.utf8.elementsEqual(source.utf8))
            let firstLineEnd = (source as NSString).range(of: "\n").location
            textView.setSelectedRange(NSRange(location: firstLineEnd, length: 0))
            let withNewline = (source as NSString).replacingCharacters(in: NSRange(location: firstLineEnd, length: 0), with: "\n  ")
            undo.beginUndoGrouping()
            start = .now
            let handledNewline = coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))
            timings["newlineDelegateCommand"] = matrixSeconds(since: start)
            XCTAssertTrue(handledNewline)
            undo.endUndoGrouping()
            XCTAssertTrue(textView.string.utf8.elementsEqual(withNewline.utf8))
            XCTAssertEqual(textView.selectedRange(), NSRange(location: firstLineEnd + 3, length: 0))
            controller.undo()
            XCTAssertTrue(textView.string.utf8.elementsEqual(source.utf8))

            let originalFrame = textView.frame
            let originalSelection = textView.selectedRange()
            let layoutCountsBefore = try XCTUnwrap(textView.qaMeasurementFullLayoutCounts)
            samples[sampleIndex]["liveFirstUnlaidCharacterIndexBeforeMeasurement"] = textView.layoutManager?.firstUnlaidCharacterIndex() ?? -1
            start = .now
            textView.setFrameSize(NSSize(width: 240, height: originalFrame.height))
            textView.layoutSubtreeIfNeeded()
            timings["resizeNarrowCall"] = matrixSeconds(since: start)
            start = .now
            let measuredNarrow = textView.measuredContentSize(forWidth: 240)
            timings["measureNarrow"] = matrixSeconds(since: start)
            let narrow = try XCTUnwrap(measuredNarrow)
            start = .now
            textView.setFrameSize(NSSize(width: 960, height: originalFrame.height))
            textView.layoutSubtreeIfNeeded()
            timings["resizeWideCall"] = matrixSeconds(since: start)
            start = .now
            let measuredWide = textView.measuredContentSize(forWidth: 960)
            timings["measureWide"] = matrixSeconds(since: start)
            let wide = try XCTUnwrap(measuredWide)
            start = .now
            let measuredAgain = textView.measuredContentSize(forWidth: 240)
            timings["measureNarrowAgain"] = matrixSeconds(since: start)
            let repeated = try XCTUnwrap(measuredAgain)
            textView.setFrameSize(originalFrame.size)
            XCTAssertEqual(repeated, narrow)
            if textView.isPlainTextMode { XCTAssertEqual(narrow.height, wide.height) }
            else { XCTAssertGreaterThanOrEqual(narrow.height, wide.height) }
            XCTAssertEqual(textView.frame, originalFrame)
            XCTAssertEqual(textView.selectedRange(), originalSelection)
            XCTAssertTrue(textView.string.utf8.elementsEqual(source.utf8))
            let layoutCountsAfter = try XCTUnwrap(textView.qaMeasurementFullLayoutCounts)
            let fullRequests = layoutCountsAfter.requests - layoutCountsBefore.requests
            let fullCompletions = layoutCountsAfter.completions - layoutCountsBefore.completions
            samples[sampleIndex]["measurementFullDocumentLayoutRequests"] = fullRequests
            samples[sampleIndex]["measurementFullDocumentLayoutCompletions"] = fullCompletions
            XCTAssertEqual(fullRequests, textView.isPlainTextMode ? 0 : 2)
            XCTAssertEqual(fullCompletions, fullRequests)
            samples[sampleIndex]["explicitMeasurementCallCount"] = 3
            samples[sampleIndex]["liveFirstUnlaidCharacterIndexAfterMeasurement"] = textView.layoutManager?.firstUnlaidCharacterIndex() ?? -1

            controller.isFindBarPresented = true
            controller.findText = "marker_"
            controller.refreshMatches()
            start = .now
            controller.dismissFindBar()
            timings["dismissSearchCancellationRequest"] = matrixSeconds(since: start)
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertFalse(controller.isSearching)
            XCTAssertEqual(controller.matchCount, 0)
            XCTAssertTrue(textView.string.utf8.elementsEqual(source.utf8), "Retaining the component must preserve its text")
            controller.isFindBarPresented = true
            controller.refreshMatches()
            let reloaded = source.replacingOccurrences(of: "marker_", with: "fresh_")
            start = .now
            textView.string = reloaded
            controller.resetForReloadedContent()
            controller.findText = "fresh_"
            controller.refreshMatches(immediately: true)
            try await waitForMatrixCompletion(controller)
            timings["externalReloadAndLatestSearchCompletion"] = matrixSeconds(since: start)
            XCTAssertEqual(controller.matchCount, 2)
            XCTAssertFalse(undo.canUndo, "External reload must discard stale undo history")
            XCTAssertTrue(textView.string.utf8.elementsEqual(reloaded.utf8))
            controller.dismissFindBar()

            let pathologicalLine = String(repeating: "a", count: 32) + "!\n"
            let pathological = String(String(repeating: pathologicalLine, count: size / pathologicalLine.utf8.count + 1).prefix(size))
            let probe = EditorMatrixRegexProbe()
            let worker = Task.detached(priority: .userInitiated) {
                let result = CodeSearchEngine.search(in: pathological,
                    query: CodeSearchQuery(text: #"(?m)^(a+)+$"#, usesRegularExpression: true),
                    observeRegex: { probe.observe($0) })
                probe.markWorkerFinished()
                return result
            }
            defer { worker.cancel() }
            var stoppedResult: CodeSearchResult?
            let completion = Task { @MainActor in stoppedResult = await worker.value }
            defer { completion.cancel() }
            let progressDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while probe.snapshot().progressCount == 0, !probe.snapshot().workerFinished, ContinuousClock.now < progressDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let beforeCancel = probe.snapshot()
            samples[sampleIndex]["pathologicalFixtureBytes"] = pathological.utf8.count
            samples[sampleIndex]["pathologicalQuery"] = "(?m)^(a+)+$"
            samples[sampleIndex]["regexProgressCallbacksBeforeCancel"] = beforeCancel.progressCount
            samples[sampleIndex]["regexInternalErrorBeforeCancel"] = beforeCancel.internalError
            samples[sampleIndex]["regexWorkerFinishedBeforeCancel"] = beforeCancel.workerFinished
            start = .now
            worker.cancel()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while stoppedResult == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let afterCancel = probe.snapshot()
            samples[sampleIndex]["regexProgressCallbacksTotal"] = afterCancel.progressCount
            samples[sampleIndex]["regexCompletedCallbackObserved"] = afterCancel.completed
            samples[sampleIndex]["regexInternalErrorObserved"] = afterCancel.internalError
            guard let stoppedResult else {
                XCTFail("Pathological regex worker did not actually stop within three seconds after cancellation")
                throw EditorMatrixFailure.cancellationDidNotStop
            }
            guard !afterCancel.internalError else {
                samples[sampleIndex]["pathologicalCancellationBoundary"] = "Regex reported internalError; empty matches are not a successful no-match or cancellation result"
                XCTFail("Regex internalError observed; inspect the diagnostic before changing product error presentation")
                throw EditorMatrixFailure.regexInternalError
            }
            guard beforeCancel.progressCount > 0, !beforeCancel.workerFinished else {
                samples[sampleIndex]["pathologicalCancellationBoundary"] = "No in-progress regex at cancellation; no cancellation latency claimed and fixture is not retried"
                XCTFail("Fixed regex fixture did not provide an observed in-progress cancellation boundary")
                throw EditorMatrixFailure.noActiveRegexProgress
            }
            timings["pathologicalRegexCancelToWorkerCompletion"] = matrixSeconds(since: start)
            samples[sampleIndex]["pathologicalCancellationBoundary"] = "First observed real regex progress, then Task.cancel to worker completion; observed at 5ms intervals, one fixed fixture with no retry"
            XCTAssertTrue(stoppedResult.ranges.isEmpty)
            samples[sampleIndex]["completed"] = true
        }
    }

    private enum EditorMatrixFailure: Error { case operationTimedOut, cancellationDidNotStop, regexInternalError, noActiveRegexProgress }

    private func matrixSeconds(since start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }

    private func waitForMatrixCompletion(_ controller: ModuleCodeEditorController) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while controller.isSearching || controller.isReplacingAll, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard !controller.isSearching, !controller.isReplacingAll else {
            XCTFail("Editor component operation did not finish within fifteen seconds")
            throw EditorMatrixFailure.operationTimedOut
        }
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

private final class EditorMatrixRegexProbe: @unchecked Sendable {
    struct Snapshot {
        var progressCount = 0
        var completed = false
        var internalError = false
        var workerFinished = false
    }
    private let lock = NSLock()
    private var value = Snapshot()

    func observe(_ observation: CodeSearchRegexObservation) {
        lock.withLock {
            if observation.progress { value.progressCount += 1 }
            value.completed = value.completed || observation.completed
            value.internalError = value.internalError || observation.internalError
        }
    }

    func markWorkerFinished() { lock.withLock { value.workerFinished = true } }
    func snapshot() -> Snapshot { lock.withLock { value } }
}
