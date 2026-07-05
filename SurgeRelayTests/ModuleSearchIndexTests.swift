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

    func testModuleSearchIndexBuildsContentIndexTokenOnlyForActiveSearch() {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let module = RelayModule(
            id: id,
            name: "Video Enhancer",
            sourceURL: "https://example.com/video.sgmodule",
            outputFileName: "Video.sgmodule",
            contentHash: "hash-1"
        )

        XCTAssertEqual(ModuleSearchIndex.contentIndexToken(for: [module], query: "  "), "idle")
        XCTAssertEqual(
            ModuleSearchIndex.contentIndexToken(for: [module], query: "  Rule  "),
            "active|rule|11111111-1111-1111-1111-111111111111:hash-1"
        )
    }

    func testModuleSearchIndexContentLoadPlanClearsWhenSearchIsEmpty() {
        let id = UUID()
        let module = RelayModule(
            id: id,
            name: "Video Enhancer",
            sourceURL: "https://example.com/video.sgmodule",
            outputFileName: "Video.sgmodule",
            contentHash: "hash-1"
        )
        let state = ModuleSearchContentIndexState(
            contentIndex: [id: "domain-suffix,example.com"],
            contentIndexCacheKeys: [id: "hash-1"]
        )

        let plan = ModuleSearchIndex.contentLoadPlan(
            modules: [module],
            query: " ",
            state: state
        )

        XCTAssertEqual(plan.retainedState, .empty)
        XCTAssertTrue(plan.modulesToLoad.isEmpty)
        XCTAssertTrue(plan.isIdle)
    }

    func testModuleSearchIndexContentLoadPlanRetainsCacheAndLoadsOnlyMetadataMisses() {
        let cached = RelayModule(
            id: UUID(),
            name: "Cached",
            sourceURL: "https://example.com/cached.sgmodule",
            outputFileName: "Cached.sgmodule",
            contentHash: "hash-cached"
        )
        let metadataHit = RelayModule(
            id: UUID(),
            name: "Streaming Tools",
            sourceURL: "https://example.com/streaming.sgmodule",
            outputFileName: "Streaming.sgmodule",
            category: "Streaming",
            contentHash: "hash-hit"
        )
        let contentMiss = RelayModule(
            id: UUID(),
            name: "Rules",
            sourceURL: "https://example.com/rules.sgmodule",
            outputFileName: "Rules.sgmodule",
            contentHash: "hash-miss"
        )
        let state = ModuleSearchContentIndexState(
            contentIndex: [cached.id: "domain-suffix,cached.example.com"],
            contentIndexCacheKeys: [cached.id: "hash-cached"]
        )

        let plan = ModuleSearchIndex.contentLoadPlan(
            modules: [cached, metadataHit, contentMiss],
            query: "domain-suffix",
            state: state
        )

        XCTAssertEqual(plan.retainedState.contentIndex, [cached.id: "domain-suffix,cached.example.com"])
        XCTAssertEqual(plan.retainedState.contentIndexCacheKeys, [cached.id: "hash-cached"])
        XCTAssertEqual(plan.modulesToLoad.map(\.id), [metadataHit.id, contentMiss.id])

        let metadataPlan = ModuleSearchIndex.contentLoadPlan(
            modules: [cached, metadataHit, contentMiss],
            query: "streaming",
            state: state
        )
        XCTAssertEqual(metadataPlan.modulesToLoad.map(\.id), [contentMiss.id])
    }

    func testModuleSearchIndexContentLoadPlanInvalidatesChangedHashes() {
        let id = UUID()
        let changed = RelayModule(
            id: id,
            name: "Video Enhancer",
            sourceURL: "https://example.com/video.sgmodule",
            outputFileName: "Video.sgmodule",
            contentHash: "hash-2"
        )
        let state = ModuleSearchContentIndexState(
            contentIndex: [id: "domain-suffix,example.com"],
            contentIndexCacheKeys: [id: "hash-1"]
        )

        let plan = ModuleSearchIndex.contentLoadPlan(
            modules: [changed],
            query: "domain-suffix",
            state: state
        )

        XCTAssertEqual(plan.retainedState, .empty)
        XCTAssertEqual(plan.modulesToLoad.map(\.id), [id])
    }
}
