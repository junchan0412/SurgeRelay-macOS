import XCTest
@testable import SurgeRelay

final class SurgeRelayTests: XCTestCase {
    func testRelayModuleSeparatesStorageLocationFromSourceOrigin() {
        let githubModule = RelayModule(
            name: "GitHub Remote",
            sourceURL: "https://example.com/loon/plugin.plugin",
            sourceFormat: .loon,
            outputFileName: "Plugin Demo",
            storageLocation: .gitHub
        )
        let localModule = RelayModule(
            name: "Local Remote",
            sourceURL: "https://example.com/qx/rewrite.conf",
            sourceFormat: .quantumultX,
            outputFileName: "Rewrite Demo.sgmodule",
            storageLocation: .local,
            localStorageRelativePath: "Rewrite Demo.sgmodule"
        )

        XCTAssertEqual(githubModule.storageLocation, .gitHub)
        XCTAssertEqual(githubModule.sourceOrigin, .remote(.loon))
        XCTAssertEqual(githubModule.publishedRelativePath, "Plugin-Demo.sgmodule")
        XCTAssertEqual(localModule.storageLocation, .local)
        XCTAssertEqual(localModule.sourceOrigin, .remote(.quantumultX))
        XCTAssertEqual(localModule.publishedRelativePath, "Rewrite Demo.sgmodule")
        XCTAssertEqual(localModule.relationshipSummary, "本地模块 · 远程 Quantumult X")
    }

    func testRefreshPolicyDoesNotRefreshAgainBeforeInterval() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(RefreshPolicy.isDue(
            lastUpdatedAt: now.addingTimeInterval(-59 * 60),
            intervalMinutes: 60,
            now: now
        ))
        XCTAssertTrue(RefreshPolicy.isDue(
            lastUpdatedAt: now.addingTimeInterval(-60 * 60),
            intervalMinutes: 60,
            now: now
        ))
        XCTAssertFalse(RefreshPolicy.isDue(lastUpdatedAt: nil, intervalMinutes: 0, now: now))
    }

    func testRelayModuleDecodesRegistryWithoutAdvancedOptions() throws {
        let original = RelayModule(
            name: "Legacy",
            sourceURL: "https://example.com/legacy.sgmodule",
            sourceFormat: .surge,
            outputFileName: "legacy"
        )
        let data = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "scriptHubOptions")
        object.removeValue(forKey: "argumentOverrides")
        object.removeValue(forKey: "iconURL")
        object.removeValue(forKey: "customIconURL")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(RelayModule.self, from: legacyData)

        XCTAssertEqual(decoded.name, "Legacy")
        XCTAssertFalse(decoded.isEnabled)
        XCTAssertEqual(decoded.scriptHubOptions, ScriptHubOptions())
        XCTAssertTrue(decoded.argumentOverrides.isEmpty)
        XCTAssertNil(decoded.iconURL)
        XCTAssertNil(decoded.customIconURL)
        XCTAssertEqual(decoded.category, "")
        XCTAssertEqual(decoded.outputFolder, "")
        XCTAssertTrue(decoded.publishesStandalone)
        XCTAssertNil(decoded.sourceETag)
        XCTAssertNil(decoded.sourceContentHash)
        XCTAssertFalse(decoded.hasOverrideConflict)
    }

    func testUpdateHistoryRoundTrip() throws {
        let entry = UpdateHistoryEntry(
            moduleName: "Demo",
            outcome: .cachedAfterFailure,
            duration: 1.25,
            message: "Timeout",
            usedCache: true
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(UpdateHistoryEntry.self, from: data)
        XCTAssertEqual(decoded.moduleName, "Demo")
        XCTAssertEqual(decoded.outcome, .cachedAfterFailure)
        XCTAssertTrue(decoded.usedCache)
    }

    func testUpdateHistoryDecodesLegacyEntryWithoutPublishDetails() throws {
        let data = Data(#"{"moduleName":"GitHub","outcome":"published","duration":0,"message":"legacy publish"}"#.utf8)

        let entry = try JSONDecoder().decode(UpdateHistoryEntry.self, from: data)

        XCTAssertEqual(entry.moduleName, "GitHub")
        XCTAssertEqual(entry.outcome, .published)
        XCTAssertEqual(entry.message, "legacy publish")
        XCTAssertTrue(entry.publishedFiles.isEmpty)
        XCTAssertTrue(entry.deletedFiles.isEmpty)
        XCTAssertNil(entry.commitSHA)
    }

    func testModuleMetadataParserFindsIconWithoutScrapingCatalog() throws {
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

    func testModuleMetadataParserAppliesCategory() {
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

    func testModuleMetadataParserReadsCategory() {
        XCTAssertEqual(ModuleMetadataParser.category(in: "#!category = 'Ads'\n[General]"), "Ads")
        XCTAssertNil(ModuleMetadataParser.category(in: "#!name=Demo\n[General]"))
    }

    func testModuleMetadataParserRemovesIconWhenApplyingSurgeMetadata() {
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

    func testMergerAddsSourceTogglesAndRemovesDeviceRestrictions() throws {
        let first = RelayModule(
            id: try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
            name: "First",
            sourceURL: "https://example.com/first.sgmodule",
            sourceFormat: .surge,
            outputFileName: "first"
        )
        let second = RelayModule(
            id: try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222")),
            name: "Second",
            sourceURL: "https://example.com/second.sgmodule",
            sourceFormat: .surge,
            outputFileName: "second"
        )
        let firstContent = """
        #!name=First
        #!system=iOS
        #!requirement=CORE_VERSION>=20 && SYSTEM = 'iOS'
        [General]
        test-setting = first
        [MITM]
        hostname = %INSERT% one.example.com
        [Script]
        # source comment
        ## source heading
        // another source comment
        ; legacy source comment
        first = type=cron, cronexp="0 0 * * *", script-path=https://example.com/one.js
        """
        let secondContent = """
        #!name=Second
        #!system=mac
        [General]
        test-setting = second
        [MITM]
        hostname = %APPEND% two.example.com
        [Script]
        second = type=cron, cronexp="0 1 * * *", script-path=https://example.com/two.js
        """
        let merged = try ModuleMerger.merge([(first, firstContent), (second, secondContent)], engineRevision: "abcdef")
        XCTAssertTrue(merged.contains("#!desc=由 Surge Relay 整合 2 个模块"))
        XCTAssertFalse(merged.contains("Script-Hub abcdef"))
        XCTAssertFalse(merged.contains("#!system="))
        XCTAssertTrue(merged.contains("#!requirement=(CORE_VERSION>=20)"))
        XCTAssertFalse(merged.contains("Relay_First"))
        XCTAssertTrue(merged.contains("first = type=cron"))
        XCTAssertFalse(merged.contains("source comment"))
        XCTAssertFalse(merged.contains("source heading"))
        XCTAssertFalse(merged.contains("# --- [Relay_"))
        XCTAssertFalse(merged.contains("# 此文件由"))
        XCTAssertTrue(merged.contains("hostname = %INSERT% one.example.com, two.example.com"))
        let mitm = try XCTUnwrap(merged.range(of: "[MITM]")?.upperBound)
        let script = try XCTUnwrap(merged.range(of: "[Script]")?.lowerBound)
        XCTAssertFalse(merged[mitm..<script].contains("# --- [Relay_"))
        XCTAssertTrue(merged.contains("test-setting = first"))
        XCTAssertFalse(merged.contains("test-setting = second"))
        XCTAssertLessThan(
            try XCTUnwrap(merged.range(of: "first = type=cron")?.lowerBound),
            try XCTUnwrap(merged.range(of: "second = type=cron")?.lowerBound)
        )
    }
}
