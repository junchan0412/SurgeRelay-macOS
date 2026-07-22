import XCTest
@testable import SurgeRelay

final class ModuleMetadataParserTests: XCTestCase {
    func testReadsSubscribedMetadataWithoutRegexFormattingAssumptions() throws {
        let content = """
          # subscribed = http://script.hub/file/_start_/https://example.com/demo.conf/_end_/Demo.sgmodule?type=qx-rewrite&target=surge-module
        [General]
        """

        let subscription = try XCTUnwrap(ModuleMetadataParser.scriptHubSubscription(in: content))
        XCTAssertEqual(subscription.originalURL, "https://example.com/demo.conf")
        XCTAssertEqual(subscription.sourceFormat, .quantumultX)
        XCTAssertNil(ModuleMetadataParser.scriptHubSubscription(in: "#!name=Self Authored\n[General]"))
    }

    func testFindsIconWithoutScrapingCatalog() throws {
        let content = """
        #!name=Demo
        #!icon = 'https://raw.githubusercontent.com/example/icons/main/demo.png'
        [General]
        """

        XCTAssertEqual(
            try XCTUnwrap(ModuleMetadataParser.iconURL(in: content)).absoluteString,
            "https://raw.githubusercontent.com/example/icons/main/demo.png"
        )
        XCTAssertNil(ModuleMetadataParser.iconURL(in: "#!name=No Icon\n[General]"))
        XCTAssertTrue(ModuleMetadataParser.applyingDisplayName("GUI Name", to: content).hasPrefix("#!name=GUI Name\n"))
    }

    func testAppliesCategory() {
        let content = """
        #!name=Demo
        #!category=Old
        [General]
        """
        let result = ModuleMetadataParser.applyingCategory("Ads", to: content)
        XCTAssertTrue(result.contains("#!category=Ads"))
        XCTAssertFalse(result.contains("#!category=Old"))
        XCTAssertEqual(ModuleMetadataParser.applyingCategory("", to: content), content)
    }

    func testReadsCategory() {
        XCTAssertEqual(ModuleMetadataParser.category(in: "#!category = 'Ads'\n[General]"), "Ads")
        XCTAssertNil(ModuleMetadataParser.category(in: "#!name=Demo\n[General]"))
    }

    func testRemovesIconWhenApplyingSurgeMetadata() {
        let content = """
        #!name=Demo
        #!icon=https://example.com/source.png
        [General]
        loglevel = notify
        """
        let result = ModuleMetadataParser.applyingModuleMetadata(name: "Managed", category: "Ads", to: content)

        XCTAssertTrue(result.contains("#!name=Managed"))
        XCTAssertTrue(result.contains("#!category=Ads"))
        XCTAssertFalse(result.localizedCaseInsensitiveContains("#!icon"))
        XCTAssertFalse(result.contains("https://example.com/source.png"))
    }

    func testSubscriptionSourceFormatRepairsConflictingQxTypeForSgmodule() throws {
        let content = """
        #SUBSCRIBED http://script.hub/file/_start_/https://example.com/modules/demo.sgmodule/_end_/Demo.sgmodule?type=qx-rewrite&target=surge-module
        """
        let subscription = try XCTUnwrap(ModuleMetadataParser.scriptHubSubscription(in: content))
        XCTAssertEqual(subscription.sourceType, "qx-rewrite")
        XCTAssertEqual(subscription.sourceFormat, .surge)
        XCTAssertEqual(subscription.originalURL, "https://example.com/modules/demo.sgmodule")
    }
}
