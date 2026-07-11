import XCTest
@testable import SurgeRelay

final class SurgeRelayTests: XCTestCase {
    func testRelayModuleSeparatesStorageLocationFromInitialSource() {
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
        let remoteOnlyModule = RelayModule(
            name: "Remote Only",
            sourceURL: "https://example.com/surge/demo.sgmodule",
            sourceFormat: .surge,
            outputFileName: "Demo",
            storageLocation: .gitHub,
            publishesStandalone: false
        )

        XCTAssertEqual(githubModule.storageLocation, .gitHub)
        XCTAssertEqual(githubModule.initialSource, .selfAuthored)
        XCTAssertEqual(githubModule.publishedRelativePath, "Plugin-Demo.sgmodule")
        XCTAssertEqual(githubModule.displayStorageLocationTitle, "GitHub 模块")
        XCTAssertEqual(localModule.storageLocation, .local)
        XCTAssertEqual(localModule.initialSource, .selfAuthored)
        XCTAssertEqual(localModule.publishedRelativePath, "Rewrite Demo.sgmodule")
        XCTAssertEqual(localModule.relationshipSummary, "本地模块 · 自写模块")
        XCTAssertEqual(localModule.standaloneStorageDetail, "储存在本地模块根目录")
        XCTAssertEqual(remoteOnlyModule.displayStorageLocationTitle, "GitHub 模块")
        XCTAssertEqual(remoteOnlyModule.displayStorageLocationSystemImage, "cloud")
        XCTAssertEqual(remoteOnlyModule.standaloneStorageDetail, "未开启独立发布；转换结果保存在本地缓存")
        XCTAssertEqual(remoteOnlyModule.relationshipSummary, "GitHub 模块 · 自写模块")
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

    func testRelayModuleDecodingUsesLegacyLocalPathAsStorageEvidence() throws {
        let legacyData = Data("""
        {
          "id": "33333333-3333-3333-3333-333333333333",
          "name": "Legacy Local",
          "sourceURL": "https://example.com/original.conf",
          "sourceFormat": "quantumultX",
          "outputFileName": "Legacy Local.sgmodule",
          "localStorageRelativePath": "Converted/Legacy Local.sgmodule"
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(RelayModule.self, from: legacyData)
        XCTAssertEqual(decoded.storageLocation, .local)
        XCTAssertEqual(decoded.localStorageRelativePath, "Converted/Legacy Local.sgmodule")
        XCTAssertTrue(decoded.preservesOutputFileName)
        XCTAssertEqual(decoded.outputFileName, "Legacy Local.sgmodule")
    }

    func testRelayModuleDecodingRepairsConflictingGitHubStorageWhenLocalPathExists() throws {
        let legacyData = Data("""
        {
          "id": "44444444-4444-4444-4444-444444444444",
          "name": "Conflicting Local",
          "sourceURL": "https://example.com/original.sgmodule",
          "sourceFormat": "surge",
          "outputFileName": "Conflicting Local.sgmodule",
          "storageLocation": "gitHub",
          "localStorageRelativePath": "Modules/Conflicting Local.sgmodule",
          "publishesStandalone": false
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(RelayModule.self, from: legacyData)

        XCTAssertEqual(decoded.storageLocation, .local)
        XCTAssertEqual(decoded.displayStorageLocationTitle, "本地模块")
        XCTAssertEqual(decoded.localStorageRelativePath, "Modules/Conflicting Local.sgmodule")
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

}
