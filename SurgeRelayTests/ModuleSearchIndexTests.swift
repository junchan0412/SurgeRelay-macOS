import XCTest
@testable import SurgeRelay

final class ModuleSearchIndexTests: XCTestCase {
    func testModuleSearchIndexIncludesDisplayedMetadata() {
        let module = RelayModule(
            name: "Video Enhancer",
            sourceURL: "https://example.com/video.sgmodule",
            sourceFormat: .surge,
            outputFileName: "Video.sgmodule",
            category: "Streaming",
            outputFolder: "Media",
            publishesStandalone: false,
            iconURL: "https://example.com/source-icon.png",
            customIconURL: "https://example.com/custom-icon.png",
            state: .current
        )

        let text = ModuleSearchIndex.text(for: module, cachedContent: "DOMAIN-SUFFIX,example.com")

        XCTAssertTrue(text.contains("streaming"))
        XCTAssertTrue(text.contains("media"))
        XCTAssertTrue(text.contains("不发布独立模块"))
        XCTAssertTrue(text.contains("source-icon.png"))
        XCTAssertTrue(text.contains("custom-icon.png"))
        XCTAssertTrue(text.contains("domain-suffix"))
        XCTAssertTrue(text.contains("已是最新"))
    }

    func testModuleSearchIndexPlansContentLoadingOnlyWhenMetadataMisses() {
        let module = RelayModule(
            name: "Video Enhancer",
            sourceURL: "https://example.com/video.sgmodule",
            sourceFormat: .surge,
            outputFileName: "Video.sgmodule",
            category: "Streaming",
            outputFolder: "Media",
            contentHash: "hash-1"
        )

        XCTAssertEqual(ModuleSearchIndex.normalizedQuery("  Streaming  "), "streaming")
        XCTAssertFalse(ModuleSearchIndex.shouldLoadContent(for: module, query: "streaming", cachedContent: nil))
        XCTAssertTrue(ModuleSearchIndex.shouldLoadContent(for: module, query: "domain-suffix", cachedContent: nil))
        XCTAssertFalse(ModuleSearchIndex.shouldLoadContent(for: module, query: "domain-suffix", cachedContent: "domain-suffix,example.com"))
        XCTAssertFalse(ModuleSearchIndex.shouldLoadContent(for: module, query: "   ", cachedContent: nil))
    }

    func testModuleSearchIndexInvalidatesCachedContentWhenHashChanges() {
        let id = UUID()
        let module = RelayModule(
            id: id,
            name: "Video Enhancer",
            sourceURL: "https://example.com/video.sgmodule",
            outputFileName: "Video.sgmodule",
            contentHash: "hash-1"
        )
        let updatedModule = RelayModule(
            id: id,
            name: "Video Enhancer",
            sourceURL: "https://example.com/video.sgmodule",
            outputFileName: "Video.sgmodule",
            contentHash: "hash-2"
        )

        XCTAssertEqual(
            ModuleSearchIndex.cachedContent(
                for: module,
                contentIndex: [id: "domain-suffix,example.com"],
                contentIndexCacheKeys: [id: "hash-1"]
            ),
            "domain-suffix,example.com"
        )
        XCTAssertNil(ModuleSearchIndex.cachedContent(
            for: updatedModule,
            contentIndex: [id: "domain-suffix,example.com"],
            contentIndexCacheKeys: [id: "hash-1"]
        ))
    }
}
