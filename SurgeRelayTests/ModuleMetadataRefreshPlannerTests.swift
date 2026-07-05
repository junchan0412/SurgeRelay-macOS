import Foundation
import XCTest
@testable import SurgeRelay

final class ModuleMetadataRefreshPlannerTests: XCTestCase {
    func testPlanRestoresSubscriptionMetadataAndOverrideBaseHash() throws {
        let cachedContent = """
        #!name=Converted
        #SUBSCRIBED http://script.hub/file/_start_/https://example.com/QuantumultX/demo.conf/_end_/Demo.sgmodule?type=qx-rewrite&target=surge-module&category=%23%E5%B7%A5%E5%85%B7&jqEnabled=true

        [Script]
        Demo = type=http-request, pattern=^https://example.com
        """
        let detectedIconURL = try XCTUnwrap(URL(string: "https://example.com/detected.png"))
        let localSourceURL = URL(filePath: "/Users/example/Surge/Demo.sgmodule").absoluteString
        let module = RelayModule(
            name: "Imported",
            sourceURL: localSourceURL,
            sourceFormat: .surge,
            outputFileName: "Demo.sgmodule",
            iconURL: "https://example.com/old.png",
            sourceETag: "etag",
            sourceLastModified: "date",
            sourceContentHash: "source-hash",
            sourceCheckedAt: Date(timeIntervalSince1970: 1),
            conversionEngineRevision: "old-engine"
        )

        let plan = ModuleMetadataRefreshPlanner.plan(
            module: module,
            cachedContent: cachedContent,
            convertedContent: "converted-content",
            hasOverride: true,
            detectedIconURL: detectedIconURL
        )

        XCTAssertTrue(plan.isChanged)
        XCTAssertEqual(plan.module.overrideBaseHash, Data("converted-content".utf8).sha256String)
        XCTAssertEqual(plan.module.sourceURL, "https://example.com/QuantumultX/demo.conf")
        XCTAssertEqual(plan.module.storageLocation, .local)
        XCTAssertTrue(plan.module.preservesOutputFileName)
        XCTAssertEqual(plan.module.sourceFormat, .quantumultX)
        XCTAssertEqual(plan.module.category, "#工具")
        XCTAssertTrue(plan.module.scriptHubOptions.enableJQ)
        XCTAssertNil(plan.module.sourceETag)
        XCTAssertNil(plan.module.sourceLastModified)
        XCTAssertNil(plan.module.sourceContentHash)
        XCTAssertNil(plan.module.sourceCheckedAt)
        XCTAssertNil(plan.module.conversionEngineRevision)
        XCTAssertEqual(plan.module.iconURL, detectedIconURL.absoluteString)
        XCTAssertNil(plan.module.detectedSourceFormat)
        XCTAssertEqual(plan.preferredIconURL, detectedIconURL)
        XCTAssertTrue(plan.shouldRefreshIconCache)
    }

    func testPlanKeepsStableCustomIconWithoutReportingChange() throws {
        let customIconURL = try XCTUnwrap(URL(string: "https://example.com/custom.png"))
        let module = RelayModule(
            name: "Stable",
            sourceURL: "https://example.com/stable.sgmodule",
            sourceFormat: .surge,
            outputFileName: "Stable",
            iconURL: customIconURL.absoluteString,
            customIconURL: customIconURL.absoluteString,
            overrideBaseHash: Data("converted-content".utf8).sha256String
        )

        let plan = ModuleMetadataRefreshPlanner.plan(
            module: module,
            cachedContent: "#!name=Stable\n[General]",
            convertedContent: "converted-content",
            hasOverride: true,
            detectedIconURL: URL(string: "https://example.com/detected.png")
        )

        XCTAssertFalse(plan.isChanged)
        XCTAssertEqual(plan.module, module)
        XCTAssertEqual(plan.preferredIconURL, customIconURL)
        XCTAssertFalse(plan.shouldRefreshIconCache)
    }

    func testPlanRemovesStaleIconWhenNoPreferredIconExists() {
        let module = RelayModule(
            name: "No Icon",
            sourceURL: "https://example.com/no-icon.sgmodule",
            sourceFormat: .surge,
            outputFileName: "No Icon",
            iconURL: "https://example.com/stale.png",
            detectedSourceFormat: .surge
        )

        let plan = ModuleMetadataRefreshPlanner.plan(
            module: module,
            cachedContent: "#!name=No Icon\n[General]",
            convertedContent: nil,
            hasOverride: false,
            detectedIconURL: nil
        )

        XCTAssertTrue(plan.isChanged)
        XCTAssertNil(plan.module.iconURL)
        XCTAssertNil(plan.preferredIconURL)
        XCTAssertTrue(plan.shouldRefreshIconCache)
    }

    func testSuccessfulConversionPlanRecordsRevisionAndOverrideConflict() throws {
        let checkedAt = Date(timeIntervalSince1970: 100)
        let updatedAt = Date(timeIntervalSince1970: 200)
        let detectedIconURL = try XCTUnwrap(URL(string: "https://example.com/icon.png"))
        let module = RelayModule(
            name: "Remote",
            sourceURL: "https://example.com/remote.conf",
            sourceFormat: .quantumultX,
            outputFileName: "Remote.sgmodule",
            contentHash: "old-hash",
            conversionEngineRevision: "old-engine",
            overrideBaseHash: Data("old-converted".utf8).sha256String,
            state: .failed,
            lastError: "previous failure"
        )
        let snapshot = SourceRevisionSnapshot(
            etag: "\"etag\"",
            lastModified: "Sat, 04 Jul 2026 12:00:00 GMT",
            contentHash: "source-hash",
            checkedAt: checkedAt
        )

        let plan = ModuleMetadataRefreshPlanner.successfulConversionPlan(
            module: module,
            revisionSnapshot: snapshot,
            nativeModule: false,
            engineRevision: "engine-2",
            convertedContent: "new-converted",
            effectiveContent: "#!name=Remote\n[Rule]\nDOMAIN-SUFFIX,example.com",
            hasOverride: true,
            detectedIconURL: detectedIconURL,
            nextContentHash: "new-hash",
            updatedAt: updatedAt
        )

        XCTAssertEqual(plan.module.sourceETag, "\"etag\"")
        XCTAssertEqual(plan.module.sourceLastModified, "Sat, 04 Jul 2026 12:00:00 GMT")
        XCTAssertEqual(plan.module.sourceContentHash, "source-hash")
        XCTAssertEqual(plan.module.sourceCheckedAt, checkedAt)
        XCTAssertEqual(plan.module.conversionEngineRevision, "engine-2")
        XCTAssertTrue(plan.module.hasOverrideConflict)
        XCTAssertEqual(plan.module.iconURL, detectedIconURL.absoluteString)
        XCTAssertEqual(plan.module.contentHash, "new-hash")
        XCTAssertEqual(plan.module.lastUpdatedAt, updatedAt)
        XCTAssertEqual(plan.module.state, .current)
        XCTAssertNil(plan.module.lastError)
        XCTAssertTrue(plan.contentChanged)
        XCTAssertEqual(plan.historyMessage, "上游已更新，本地编辑需要确认")
        XCTAssertEqual(plan.preferredIconURL, detectedIconURL)
        XCTAssertTrue(plan.shouldRefreshIconCache)
    }

    func testSuccessfulConversionPlanRestoresSubscriptionMetadataForLocalImports() throws {
        let updatedAt = Date(timeIntervalSince1970: 300)
        let effectiveContent = """
        #!name=Converted
        #SUBSCRIBED http://script.hub/file/_start_/https://example.com/QuantumultX/demo.conf/_end_/Demo.sgmodule?type=qx-rewrite&target=surge-module&category=%23%E5%B7%A5%E5%85%B7&jqEnabled=true

        [Script]
        Demo = type=http-request, pattern=^https://example.com
        """
        let localSourceURL = URL(filePath: "/Users/example/Surge/Demo.sgmodule").absoluteString
        let module = RelayModule(
            name: "Imported",
            sourceURL: localSourceURL,
            sourceFormat: .surge,
            outputFileName: "Demo.sgmodule",
            sourceETag: "etag",
            sourceLastModified: "date",
            sourceContentHash: "source-hash",
            sourceCheckedAt: Date(timeIntervalSince1970: 1),
            conversionEngineRevision: "old-engine"
        )
        let snapshot = SourceRevisionSnapshot(
            etag: "fresh-etag",
            lastModified: "fresh-date",
            contentHash: "fresh-source-hash",
            checkedAt: Date(timeIntervalSince1970: 2)
        )

        let plan = ModuleMetadataRefreshPlanner.successfulConversionPlan(
            module: module,
            revisionSnapshot: snapshot,
            nativeModule: false,
            engineRevision: "engine-2",
            convertedContent: "converted",
            effectiveContent: effectiveContent,
            hasOverride: false,
            detectedIconURL: nil,
            nextContentHash: "content-hash",
            updatedAt: updatedAt
        )

        XCTAssertEqual(plan.module.sourceURL, "https://example.com/QuantumultX/demo.conf")
        XCTAssertEqual(plan.module.storageLocation, .local)
        XCTAssertTrue(plan.module.preservesOutputFileName)
        XCTAssertEqual(plan.module.sourceFormat, .quantumultX)
        XCTAssertEqual(plan.module.category, "#工具")
        XCTAssertTrue(plan.module.scriptHubOptions.enableJQ)
        XCTAssertNil(plan.module.sourceETag)
        XCTAssertNil(plan.module.sourceLastModified)
        XCTAssertNil(plan.module.sourceContentHash)
        XCTAssertNil(plan.module.sourceCheckedAt)
        XCTAssertNil(plan.module.conversionEngineRevision)
        XCTAssertFalse(plan.module.hasOverrideConflict)
        XCTAssertEqual(plan.module.contentHash, "content-hash")
        XCTAssertEqual(plan.module.lastUpdatedAt, updatedAt)
        XCTAssertTrue(plan.contentChanged)
        XCTAssertEqual(plan.historyMessage, "转换完成")
    }

    func testUnchangedCachedContentPlanOnlyRefreshesSourceRevisionAndState() {
        let lastUpdatedAt = Date(timeIntervalSince1970: 10)
        let checkedAt = Date(timeIntervalSince1970: 20)
        let module = RelayModule(
            name: "Cached",
            sourceURL: "https://example.com/cached.sgmodule",
            sourceFormat: .surge,
            outputFileName: "Cached.sgmodule",
            lastUpdatedAt: lastUpdatedAt,
            contentHash: "content-hash",
            sourceETag: "old-etag",
            sourceLastModified: "old-date",
            sourceContentHash: "old-source-hash",
            sourceCheckedAt: Date(timeIntervalSince1970: 1),
            conversionEngineRevision: "engine-1",
            overrideBaseHash: "override-base",
            hasOverrideConflict: true,
            state: .failed,
            lastError: "previous failure"
        )
        let snapshot = SourceRevisionSnapshot(
            etag: "new-etag",
            lastModified: "new-date",
            contentHash: "new-source-hash",
            checkedAt: checkedAt
        )

        let plan = ModuleMetadataRefreshPlanner.unchangedCachedContentPlan(
            module: module,
            revisionSnapshot: snapshot
        )

        XCTAssertEqual(plan.module.sourceETag, "new-etag")
        XCTAssertEqual(plan.module.sourceLastModified, "new-date")
        XCTAssertEqual(plan.module.sourceContentHash, "new-source-hash")
        XCTAssertEqual(plan.module.sourceCheckedAt, checkedAt)
        XCTAssertEqual(plan.module.state, .current)
        XCTAssertNil(plan.module.lastError)
        XCTAssertEqual(plan.module.lastUpdatedAt, lastUpdatedAt)
        XCTAssertEqual(plan.module.contentHash, "content-hash")
        XCTAssertEqual(plan.module.conversionEngineRevision, "engine-1")
        XCTAssertEqual(plan.module.overrideBaseHash, "override-base")
        XCTAssertTrue(plan.module.hasOverrideConflict)
        XCTAssertEqual(plan.historyMessage, "来源内容没有变化")
    }
}
