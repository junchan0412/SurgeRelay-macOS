import Foundation
import XCTest
@testable import SurgeRelay

final class ModulePreviewEditPlannerTests: XCTestCase {
    func testSavePlanSkipsUnchangedNamedContent() {
        let module = RelayModule(
            name: "No Change",
            sourceURL: "https://example.com/no-change.sgmodule",
            outputFileName: "NoChange.sgmodule",
            overrideBaseHash: "existing-base",
            hasOverrideConflict: true
        )

        let plan = ModulePreviewEditPlanner.savePlan(
            module: module,
            namedContent: "#!name=No Change",
            currentContent: "#!name=No Change",
            convertedContent: "converted",
            automaticallyPublish: true
        )

        XCTAssertFalse(plan.shouldWriteOverride)
        XCTAssertEqual(plan.overrideContent, "#!name=No Change")
        XCTAssertEqual(plan.module.overrideBaseHash, "existing-base")
        XCTAssertTrue(plan.module.hasOverrideConflict)
        XCTAssertEqual(plan.statusMessage, "内容没有变化")
    }

    func testSavePlanWritesOverrideAndClearsConflictWhenConvertedContentIsAvailable() {
        let module = RelayModule(
            name: "Edited",
            sourceURL: "https://example.com/edited.sgmodule",
            outputFileName: "Edited.sgmodule",
            overrideBaseHash: "old-base",
            hasOverrideConflict: true
        )

        let plan = ModulePreviewEditPlanner.savePlan(
            module: module,
            namedContent: "new content",
            currentContent: "old content",
            convertedContent: "fresh converted",
            automaticallyPublish: true
        )

        XCTAssertTrue(plan.shouldWriteOverride)
        XCTAssertEqual(plan.overrideContent, "new content")
        XCTAssertEqual(plan.module.overrideBaseHash, Data("fresh converted".utf8).sha256String)
        XCTAssertFalse(plan.module.hasOverrideConflict)
        XCTAssertEqual(plan.statusMessage, "已写入 Edited，等待合并发布")
    }

    func testSavePlanKeepsExistingConflictStateWhenConvertedContentIsUnavailable() {
        let module = RelayModule(
            name: "Edited",
            sourceURL: "https://example.com/edited.sgmodule",
            outputFileName: "Edited.sgmodule",
            overrideBaseHash: "old-base",
            hasOverrideConflict: true
        )

        let plan = ModulePreviewEditPlanner.savePlan(
            module: module,
            namedContent: "new content",
            currentContent: nil,
            convertedContent: nil,
            automaticallyPublish: false
        )

        XCTAssertTrue(plan.shouldWriteOverride)
        XCTAssertEqual(plan.module.overrideBaseHash, "old-base")
        XCTAssertTrue(plan.module.hasOverrideConflict)
        XCTAssertEqual(plan.statusMessage, "已写入 Edited")
    }

    func testRestorePlanClearsOverrideStateAndUsesAutomaticPublishStatus() {
        let module = RelayModule(
            name: "Restored",
            sourceURL: "https://example.com/restored.sgmodule",
            outputFileName: "Restored.sgmodule",
            overrideBaseHash: "old-base",
            hasOverrideConflict: true
        )

        let plan = ModulePreviewEditPlanner.restorePlan(
            module: module,
            automaticallyPublish: true
        )

        XCTAssertNil(plan.module.overrideBaseHash)
        XCTAssertFalse(plan.module.hasOverrideConflict)
        XCTAssertEqual(plan.statusMessage, "已恢复 Restored 的转换结果，等待合并发布")
    }

    func testAcceptConflictPlanRefreshesBaseHashAndClearsConflict() {
        let module = RelayModule(
            name: "Conflict",
            sourceURL: "https://example.com/conflict.sgmodule",
            outputFileName: "Conflict.sgmodule",
            overrideBaseHash: "stale-base",
            hasOverrideConflict: true
        )

        let plan = ModulePreviewEditPlanner.acceptConflictPlan(
            module: module,
            convertedContent: "accepted converted"
        )

        XCTAssertEqual(plan.module.overrideBaseHash, Data("accepted converted".utf8).sha256String)
        XCTAssertFalse(plan.module.hasOverrideConflict)
        XCTAssertEqual(plan.statusMessage, "已保留 Conflict 的本地编辑")
    }
}
