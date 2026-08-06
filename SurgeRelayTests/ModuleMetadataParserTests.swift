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

    func testAppliesCustomIconWhenApplyingSurgeMetadata() {
        let content = """
        #!name=Demo
        #!icon=https://example.com/source.png
        [General]
        loglevel = notify
        """
        let result = ModuleMetadataParser.applyingModuleMetadata(
            name: "Managed",
            category: "Ads",
            iconURL: "https://example.com/custom.png",
            to: content
        )

        XCTAssertTrue(result.contains("#!name=Managed"))
        XCTAssertTrue(result.contains("#!category=Ads"))
        XCTAssertTrue(result.contains("#!icon=https://example.com/custom.png"))
        XCTAssertFalse(result.contains("https://example.com/source.png"))
    }

    func testPreservesSourceIconWithoutCustomIcon() {
        let content = """
        #!name=Demo
        #!icon=https://example.com/source.png
        [General]
        loglevel = notify
        """
        let result = ModuleMetadataParser.applyingModuleMetadata(name: "Managed", category: "Ads", to: content)

        XCTAssertTrue(result.contains("#!name=Managed"))
        XCTAssertTrue(result.contains("#!category=Ads"))
        XCTAssertTrue(result.contains("#!icon=https://example.com/source.png"))
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

    func testRecoversSubscriptionInitialAddressFromRegisteredScriptHubURL() throws {
        let source = """
        https://script.hub/file/_start_/https://raw.githubusercontent.com/example/repo/main/QuantumultX/demo.conf/_end_/Demo.sgmodule?type=qx-rewrite&target=surge-module&category=%23%E5%B7%A5%E5%85%B7&del=false&jqEnabled=true
        """
        let subscription = try XCTUnwrap(ModuleMetadataParser.scriptHubSubscription(from: source))
        XCTAssertEqual(
            subscription.originalURL,
            "https://raw.githubusercontent.com/example/repo/main/QuantumultX/demo.conf"
        )
        XCTAssertEqual(subscription.sourceFormat, .quantumultX)
        XCTAssertEqual(subscription.category, "#工具")
        XCTAssertTrue(subscription.options.enableJQ)
        XCTAssertNil(ModuleMetadataParser.scriptHubSubscription(from: "https://example.com/demo.sgmodule"))
    }

    func testApplyingScriptHubSubscriptionInsertsMarkerAfterName() {
        let content = "#!name=Demo\n[General]\n"
        let subscription = ScriptHubSubscriptionInfo(
            subscriptionURL: "http://script.hub/file/_start_/https://example.com/demo.conf/_end_/Demo.sgmodule?type=surge-module&target=surge-module",
            originalURL: "https://example.com/demo.conf",
            outputName: "Demo.sgmodule",
            sourceType: "surge-module",
            target: "surge-module",
            category: nil,
            options: ScriptHubOptions()
        )
        let result = ModuleMetadataParser.applyingScriptHubSubscription(subscription, to: content)
        XCTAssertTrue(result.hasPrefix("#!name=Demo\n"))
        XCTAssertTrue(result.contains("#SUBSCRIBED http://script.hub/file/_start_/https://example.com/demo.conf/_end_/Demo.sgmodule"))
        let nameRange = result.range(of: "#!name=Demo")!
        let subRange = result.range(of: "#SUBSCRIBED")!
        XCTAssertTrue(nameRange.upperBound < subRange.lowerBound)
    }

    func testApplyingScriptHubSubscriptionReplacesExistingMarker() {
        let content = "#!name=Demo\n#SUBSCRIBED http://script.hub/file/_start_/https://old.com/old.conf/_end_/Demo.sgmodule\n[General]\n"
        let subscription = ScriptHubSubscriptionInfo(
            subscriptionURL: "http://script.hub/file/_start_/https://new.com/new.conf/_end_/Demo.sgmodule?type=surge-module&target=surge-module",
            originalURL: "https://new.com/new.conf",
            outputName: "Demo.sgmodule",
            sourceType: "surge-module",
            target: "surge-module",
            category: nil,
            options: ScriptHubOptions()
        )
        let result = ModuleMetadataParser.applyingScriptHubSubscription(subscription, to: content)
        XCTAssertTrue(result.contains("#SUBSCRIBED http://script.hub/file/_start_/https://new.com/new.conf/_end_/Demo.sgmodule"))
        XCTAssertFalse(result.contains("https://old.com/old.conf"))
    }

    func testApplyingScriptHubSubscriptionPreservesContentWhenNil() {
        let content = "#!name=Demo\n[General]\n"
        XCTAssertEqual(ModuleMetadataParser.applyingScriptHubSubscription(nil, to: content), content)
    }
}
