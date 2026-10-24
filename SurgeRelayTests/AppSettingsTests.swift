import XCTest
@testable import SurgeRelay

final class AppSettingsTests: XCTestCase {
    func testExplicitlyDisabledPublishTargetsRemainDisabled() throws {
        for mode in ["local", "gitHub"] {
            let json = """
            {"storageMode":"\(mode)","publishToLocal":false,"publishToGitHub":false,"webServerEnabled":false}
            """
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
            XCTAssertFalse(settings.publishToLocal)
            XCTAssertFalse(settings.publishToGitHub)
            XCTAssertFalse(settings.webServerEnabled)
            let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertFalse(restored.publishToLocal)
            XCTAssertFalse(restored.publishToGitHub)
            XCTAssertEqual(restored.storageMode, settings.storageMode)
        }
    }

    func testLegacyMissingPublishFlagsStillFollowStorageMode() throws {
        let local = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"storageMode":"local"}"#.utf8))
        XCTAssertTrue(local.publishToLocal)
        XCTAssertFalse(local.publishToGitHub)
        let github = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"storageMode":"gitHub"}"#.utf8))
        XCTAssertFalse(github.publishToLocal)
        XCTAssertTrue(github.publishToGitHub)
        let defaultSettings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(defaultSettings.publishToLocal)
        XCTAssertTrue(defaultSettings.publishToGitHub)
    }

    func testSettingsDecodeWithoutSyncedTokenOrRepositoryVisibility() throws {
        let data = Data(#"{"github":{"owner":"someone","repository":"relay","branch":"main","directory":"modules"}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.githubToken, "")
        XCTAssertNil(settings.github.repositoryIsPrivate)
        XCTAssertNil(settings.localPublishedRootDirectory)
        XCTAssertTrue(settings.localPublishedFilePaths.isEmpty)
        XCTAssertNil(settings.githubPublishedRepositoryKey)
        XCTAssertTrue(settings.githubPublishedFilePaths.isEmpty)
        XCTAssertTrue(settings.customModuleOutputFolders.isEmpty)
    }

    func testSettingsMigratesFloatingScriptHubUpstreamURL() throws {
        for revision in ["main", "master", "HEAD"] {
            let data = Data("""
            {
              "scriptHubModuleURL": "https://raw.githubusercontent.com/Script-Hub-Org/Script-Hub/\(revision)/modules/script-hub.surge.sgmodule"
            }
            """.utf8)
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)

            XCTAssertEqual(settings.scriptHubModuleURL, AppSettings.defaultScriptHubModuleURL)
        }
    }

    func testSettingsKeepsPinnedOrCustomScriptHubUpstreamURL() throws {
        let tagURL = "https://raw.githubusercontent.com/Script-Hub-Org/Script-Hub/v1.0.0/modules/script-hub.surge.sgmodule"
        let customURL = "https://example.com/script-hub.surge.sgmodule"

        XCTAssertEqual(
            try JSONDecoder().decode(AppSettings.self, from: Data(#"{"scriptHubModuleURL":"\#(tagURL)"}"#.utf8)).scriptHubModuleURL,
            tagURL
        )
        XCTAssertEqual(
            try JSONDecoder().decode(AppSettings.self, from: Data(#"{"scriptHubModuleURL":"\#(customURL)"}"#.utf8)).scriptHubModuleURL,
            customURL
        )
    }

    func testSettingsDecodesCustomModuleOutputFolders() throws {
        let data = Data(#"{"customModuleOutputFolders":["Ads","Tools/Nested"]}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.customModuleOutputFolders, ["Ads", "Tools/Nested"])
    }

    func testSettingsStillDecodesLegacyGitHubTokenForMigration() throws {
        let data = Data(#"{"githubToken":"ghp_legacy","github":{"owner":"someone","repository":"relay","branch":"main","directory":"modules"}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.githubToken, "ghp_legacy")
    }



    func testLegacyAggregateSettingsAreIgnoredAndNotEncoded() throws {
        let data = Data(#"{"combinedModuleEnabled":true,"combinedModuleFileName":"Old Collection"}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.legacyCombinedModuleFileName, "Old Collection")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        XCTAssertNil(json["combinedModuleEnabled"])
        XCTAssertNil(json["combinedModuleFileName"])
        let moduleData = Data(#"{"id":"11111111-1111-1111-1111-111111111111","name":"Old","sourceURL":"https://test.invalid/source","outputFileName":"Old","publishesStandalone":false,"isEnabled":true}"#.utf8)
        let module = try JSONDecoder().decode(RelayModule.self, from: moduleData)
        XCTAssertTrue(PublishCoordinator.shouldPublishStandalone(module, destination: .gitHub))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(module)) as? [String: Any])
        XCTAssertNil(encoded["isEnabled"])
        XCTAssertNil(encoded["publishesStandalone"])
    }

    func testAppSettingsDefaultEnablesLaunchUpdate() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(settings.automaticallyUpdateOnLaunch)
    }

    func testAppSettingsDecodeLaunchUpdateFalse() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"automaticallyUpdateOnLaunch":false}"#.utf8))
        XCTAssertFalse(settings.automaticallyUpdateOnLaunch)
    }

    func testModuleFilterMatching() {
        var module = RelayModule(
            name: "Demo",
            sourceURL: "https://example.com/test.sgmodule",
            outputFileName: "Demo"
        )
        XCTAssertEqual(ModuleFilter.all.matches(module), true)
        XCTAssertEqual(ModuleFilter.updatable.matches(module), true)
        XCTAssertEqual(ModuleFilter.nonUpdatable.matches(module), false)

        module = RelayModule(
            name: "Local Demo",
            sourceURL: URL(filePath: "/tmp/demo.sgmodule").absoluteString,
            outputFileName: "Demo.sgmodule",
            storageLocation: .local
        )
        XCTAssertEqual(ModuleFilter.updatable.matches(module), true)
        XCTAssertEqual(ModuleFilter.nonUpdatable.matches(module), false)
        XCTAssertEqual(ModuleFilter.local.matches(module), true)
        XCTAssertEqual(ModuleFilter.github.matches(module), false)

        module = RelayModule(
            name: "Enabled",
            sourceURL: "https://example.com/test.sgmodule",
            outputFileName: "Demo"
        )


        let counts = ModuleFilter.counts(
            for: [module]
        )
    }

    func testModuleExtendedFilterMatching() {
        let remote = RelayModule(
            name: "Remote",
            sourceURL: "https://example.com/a.sgmodule",
            outputFileName: "A"
        )
        XCTAssertTrue(ModuleFilter.remoteSource.matches(remote))
        XCTAssertFalse(ModuleFilter.selfAuthored.matches(remote))

        let subscribed = RelayModule(
            name: "Sub",
            sourceURL: "https://example.com/sub.sgmodule",
            outputFileName: "Sub",
            scriptHubSubscription: ScriptHubSubscriptionInfo(
                subscriptionURL: "https://script.hub/convert?url=abc",
                originalURL: "https://raw.githubusercontent.com/owner/repo/main/x.sgmodule",
                options: ScriptHubOptions()
            )
        )
        XCTAssertTrue(ModuleFilter.subscribed.matches(subscribed))
        XCTAssertFalse(ModuleFilter.selfAuthored.matches(subscribed))

        let selfAuthored = RelayModule(
            name: "Self",
            sourceURL: URL(filePath: "/tmp/self.sgmodule").absoluteString,
            outputFileName: "Self.sgmodule",
            storageLocation: .local
        )
        XCTAssertTrue(ModuleFilter.selfAuthored.matches(selfAuthored))

        let failed = RelayModule(
            name: "Fail",
            sourceURL: "https://example.com/f.sgmodule",
            outputFileName: "F",
            state: .failed
        )
        XCTAssertTrue(ModuleFilter.failed.matches(failed))
        XCTAssertTrue(ModuleFilter.attention.matches(failed))

        let never = RelayModule(
            name: "Never",
            sourceURL: "https://example.com/n.sgmodule",
            outputFileName: "N",
            state: .never
        )
        XCTAssertTrue(ModuleFilter.neverUpdated.matches(never))

        let conflict = RelayModule(
            name: "Conflict",
            sourceURL: "https://example.com/c.sgmodule",
            outputFileName: "C",
            hasOverrideConflict: true
        )
        XCTAssertTrue(ModuleFilter.overrideConflict.matches(conflict))
        XCTAssertTrue(ModuleFilter.attention.matches(conflict))

        let cached = RelayModule(
            name: "Cached",
            sourceURL: "https://example.com/x.sgmodule",
            outputFileName: "X"
        )
        XCTAssertTrue(PublishCoordinator.shouldPublishStandalone(cached, destination: .gitHub))

        let github = RelayModule(
            name: "GH",
            sourceURL: "https://example.com/gh.sgmodule",
            outputFileName: "GH",
            storageLocation: .gitHub
        )
        XCTAssertTrue(ModuleFilter.github.matches(github))
        XCTAssertFalse(ModuleFilter.local.matches(github))
    }

    func testModuleFilterGroupingAndPresets() {
        XCTAssertEqual(ModuleFilter.quickPresets, [.all, .updatable, .nonUpdatable, .attention])
        XCTAssertTrue(ModuleFilter.all.isQuickPreset)
        XCTAssertTrue(ModuleFilter.updatable.isQuickPreset)
        XCTAssertFalse(ModuleFilter.failed.isQuickPreset)
        XCTAssertEqual(ModuleFilter.failed.group, .updateState)
        XCTAssertEqual(ModuleFilter.local.group, .storage)
        XCTAssertEqual(ModuleFilter.github.group, .storage)
        XCTAssertEqual(ModuleFilter.subscribed.group, .source)
        XCTAssertEqual(ModuleFilter.remoteSource.group, .source)
        XCTAssertEqual(ModuleFilter.selfAuthored.group, .source)
        XCTAssertEqual(ModuleFilter.attention.group, .status)
        XCTAssertNil(ModuleFilter.all.group)
    }

    func testModuleSortOrder() {
        let alpha = RelayModule(
            name: "alpha",
            sourceURL: "https://example.com/alpha.sgmodule",
            outputFileName: "A",
            createdAt: Date(timeIntervalSince1970: 100),
            lastUpdatedAt: Date(timeIntervalSince1970: 300)
        )
        let bravo = RelayModule(
            name: "Bravo",
            sourceURL: "https://example.com/bravo.sgmodule",
            outputFileName: "B",
            createdAt: Date(timeIntervalSince1970: 200),
            lastUpdatedAt: Date(timeIntervalSince1970: 200)
        )
        let charlie = RelayModule(
            name: "charlie",
            sourceURL: "https://example.com/charlie.sgmodule",
            outputFileName: "C",
            createdAt: Date(timeIntervalSince1970: 300),
            lastUpdatedAt: Date(timeIntervalSince1970: 100)
        )
        let shuffled = [charlie, alpha, bravo]
        XCTAssertEqual(ModuleSortOrder.nameAsc.sorted(shuffled).map(\.name), ["alpha", "Bravo", "charlie"])
        XCTAssertEqual(ModuleSortOrder.nameDesc.sorted(shuffled).map(\.name), ["charlie", "Bravo", "alpha"])
        XCTAssertEqual(ModuleSortOrder.lastUpdated.sorted(shuffled).map(\.name), ["alpha", "Bravo", "charlie"])
        XCTAssertEqual(ModuleSortOrder.createdAt.sorted(shuffled).map(\.name), ["charlie", "Bravo", "alpha"])
    }
}