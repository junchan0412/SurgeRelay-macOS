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
}
