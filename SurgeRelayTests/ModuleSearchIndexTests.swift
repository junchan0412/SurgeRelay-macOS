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
                contentIndexCacheKeys: [id: ModuleSearchIndex.contentCacheKey(for: module)]
            ),
            "domain-suffix,example.com"
        )
        XCTAssertNil(ModuleSearchIndex.cachedContent(
            for: updatedModule,
            contentIndex: [id: "domain-suffix,example.com"],
            contentIndexCacheKeys: [id: ModuleSearchIndex.contentCacheKey(for: module)]
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
            "active|rule|11111111-1111-1111-1111-111111111111:\(ModuleSearchIndex.contentCacheKey(for: module))"
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
            contentIndexCacheKeys: [id: ModuleSearchIndex.contentCacheKey(for: module)]
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
            contentIndexCacheKeys: [cached.id: ModuleSearchIndex.contentCacheKey(for: cached)]
        )

        let plan = ModuleSearchIndex.contentLoadPlan(
            modules: [cached, metadataHit, contentMiss],
            query: "domain-suffix",
            state: state
        )

        XCTAssertEqual(plan.retainedState.contentIndex, [cached.id: "domain-suffix,cached.example.com"])
        XCTAssertEqual(plan.retainedState.contentIndexCacheKeys, state.contentIndexCacheKeys)
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
        var previous = changed
        previous.contentHash = "hash-1"
        let state = ModuleSearchContentIndexState(
            contentIndex: [id: "domain-suffix,example.com"],
            contentIndexCacheKeys: [id: ModuleSearchIndex.contentCacheKey(for: previous)]
        )

        let plan = ModuleSearchIndex.contentLoadPlan(
            modules: [changed],
            query: "domain-suffix",
            state: state
        )

        XCTAssertEqual(plan.retainedState, .empty)
        XCTAssertEqual(plan.modulesToLoad.map(\.id), [id])
    }

    func testModuleSearchIndexFilterPlanReusesMetadataCache() {
        let module = RelayModule(
            name: "Video Enhancer",
            sourceURL: "https://example.com/video.sgmodule",
            sourceFormat: .surge,
            outputFileName: "Video.sgmodule",
            category: "Streaming",
            contentHash: "hash-1"
        )
        let first = ModuleSearchIndex.filterPlan(
            modules: [module],
            query: "streaming",
            contentState: .empty,
            metadataState: .empty
        )
        XCTAssertEqual(first.matches.map(\.id), [module.id])
        XCTAssertEqual(first.metadataState.metadataIndexCacheKeys[module.id], ModuleSearchIndex.metadataCacheKey(for: module))
        XCTAssertEqual(first.metadataState.metadataIndex[module.id]?.contains("streaming"), true)

        let second = ModuleSearchIndex.filterPlan(
            modules: [module],
            query: "missing-token",
            contentState: .empty,
            metadataState: first.metadataState
        )
        XCTAssertTrue(second.matches.isEmpty)
        XCTAssertEqual(second.metadataState.metadataIndexCacheKeys[module.id], first.metadataState.metadataIndexCacheKeys[module.id])
        XCTAssertEqual(second.metadataState.metadataIndex[module.id], first.metadataState.metadataIndex[module.id])
    }

    func testModuleSearchIndexMetadataCacheKeyChangesWithState() {
        let base = RelayModule(
            name: "Video Enhancer",
            sourceURL: "https://example.com/video.sgmodule",
            outputFileName: "Video.sgmodule",
            state: .current
        )
        var failed = base
        failed.state = .failed
        failed.lastError = "404"
        XCTAssertNotEqual(
            ModuleSearchIndex.metadataCacheKey(for: base),
            ModuleSearchIndex.metadataCacheKey(for: failed)
        )
    }

    func testSearchDropsOldPreviewHeadersAfterRenaming() {
        let original = RelayModule(
            name: "PreviousName",
            sourceURL: "https://example.com/source.sgmodule",
            outputFileName: "Source.sgmodule",
            contentHash: "unchanged-body"
        )
        let contentState = ModuleSearchContentIndexState(
            contentIndex: [original.id: "#!name=previousname\n[rule]\nfinal,direct"],
            contentIndexCacheKeys: [original.id: ModuleSearchIndex.contentCacheKey(for: original)]
        )
        var renamed = original
        renamed.name = "CurrentName"

        let filtered = ModuleSearchIndex.filterPlan(
            modules: [renamed], query: "previousname", contentState: contentState, metadataState: .empty
        )
        let load = ModuleSearchIndex.contentLoadPlan(modules: [renamed], query: "final,direct", state: contentState)

        XCTAssertTrue(filtered.matches.isEmpty)
        XCTAssertEqual(load.modulesToLoad.map(\.id), [renamed.id])
        XCTAssertEqual(load.retainedState, .empty)
    }

    func testDescriptionEditsAreSearchableWithoutLoadingContent() {
        var module = RelayModule(
            name: "Source",
            sourceURL: "https://example.com/source.sgmodule",
            outputFileName: "Source.sgmodule",
            moduleDescription: "Previous description"
        )
        let previous = ModuleSearchIndex.filterPlan(
            modules: [module], query: "previous description", contentState: .empty, metadataState: .empty
        )
        XCTAssertEqual(previous.matches.map(\.id), [module.id])
        module.moduleDescription = "Revised description"

        let updated = ModuleSearchIndex.filterPlan(
            modules: [module], query: "revised description", contentState: .empty, metadataState: previous.metadataState
        )
        XCTAssertEqual(updated.matches.map(\.id), [module.id])
        XCTAssertFalse(ModuleSearchIndex.shouldLoadContent(for: module, query: "revised description", cachedContent: nil))
        XCTAssertFalse(updated.metadataState.metadataIndex[module.id]?.contains("previous description") ?? true)
    }

    func testSearchRefreshesWhenAddingAGitHubTargetToALocalModule() {
        var module = RelayModule(
            name: "Source",
            sourceURL: "file:///tmp/source.sgmodule",
            outputFileName: "Source.sgmodule",
            storageTargets: [.local]
        )
        let previous = ModuleSearchIndex.filterPlan(
            modules: [module], query: "同时储存", contentState: .empty, metadataState: .empty
        )
        XCTAssertTrue(previous.matches.isEmpty)
        module.storageTargets.insert(.gitHub)

        let updated = ModuleSearchIndex.filterPlan(
            modules: [module], query: "同时储存", contentState: .empty, metadataState: previous.metadataState
        )

        XCTAssertEqual(updated.matches.map(\.id), [module.id])
    }

    func testPreviewMetadataEditsInvalidateContentButProgressChangesDoNot() {
        let original = RelayModule(
            name: "Source",
            sourceURL: "https://example.com/source.sgmodule",
            outputFileName: "Source.sgmodule",
            contentHash: "unchanged-body"
        )
        let state = ModuleSearchContentIndexState(
            contentIndex: [original.id: "[rule]\nfinal,direct"],
            contentIndexCacheKeys: [original.id: ModuleSearchIndex.contentCacheKey(for: original)]
        )
        let previewEdits: [(inout RelayModule) -> Void] = [
            { $0.category = "Updated category" },
            { $0.moduleDescription = "Updated description" },
            { $0.customIconURL = "https://example.com/updated.png" },
            { $0.outputFileName = "Updated.sgmodule" },
            { $0.sourceURL = "https://example.com/updated.sgmodule" },
            { $0.sourceFormat = .surge },
            { $0.scriptHubOptions.policy = "Updated policy" },
            { $0.argumentOverrides = ["Mode": "PROXY"] }
        ]
        for edit in previewEdits {
            var updated = original
            edit(&updated)
            let plan = ModuleSearchIndex.contentLoadPlan(modules: [updated], query: "final,direct", state: state)
            XCTAssertEqual(plan.modulesToLoad.map(\.id), [original.id])
            XCTAssertEqual(plan.retainedState, .empty)
        }

        var updating = original
        updating.state = .updating
        updating.sourceCheckedAt = .now
        updating.storageTargets = [.local, .gitHub]
        let retained = ModuleSearchIndex.contentLoadPlan(modules: [updating], query: "final,direct", state: state)
        XCTAssertTrue(retained.modulesToLoad.isEmpty)
        XCTAssertEqual(retained.retainedState, state)
    }
}
