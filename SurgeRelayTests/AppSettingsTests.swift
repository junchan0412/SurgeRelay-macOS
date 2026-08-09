import XCTest
@testable import SurgeRelay

final class AppSettingsTests: XCTestCase {
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

    func testStorageModeSelectsOnlyItsOwnCombinedOutput() throws {
        var settings = AppSettings()
        settings.combinedModuleEnabled = true
        settings.combinedModuleFileName = "My Relay"
        settings.localModuleDirectory = "/tmp/Surge Relay"
        settings.github.repositoryIsPrivate = false

        settings.publishToLocal = true
        settings.publishToGitHub = false
        XCTAssertNil(PublishedAddressResolver.githubURL(for: "My-Relay.sgmodule", settings: settings))
        XCTAssertEqual(
            try XCTUnwrap(PublishedAddressResolver.combinedLocalFileURL(settings: settings)).path,
            "/tmp/Surge Relay/My-Relay.sgmodule"
        )

        settings.publishToGitHub = true
        XCTAssertEqual(
            try XCTUnwrap(PublishedAddressResolver.combinedLocalFileURL(settings: settings)).path,
            "/tmp/Surge Relay/My-Relay.sgmodule"
        )
        XCTAssertEqual(
            try XCTUnwrap(PublishedAddressResolver.githubURL(for: "My-Relay.sgmodule", settings: settings)).host,
            "raw.githubusercontent.com"
        )
    }

    func testAppSettingsDefaultDisablesCombinedModule() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(settings.combinedModuleEnabled)
        XCTAssertNil(PublishedAddressResolver.combinedLocalFileURL(settings: settings))
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
        XCTAssertEqual(ModuleFilter.all.matches(module, combinedModuleEnabled: true), true)
        XCTAssertEqual(ModuleFilter.updatable.matches(module, combinedModuleEnabled: true), true)
        XCTAssertEqual(ModuleFilter.nonUpdatable.matches(module, combinedModuleEnabled: true), false)

        module = RelayModule(
            name: "Local Demo",
            sourceURL: URL(filePath: "/tmp/demo.sgmodule").absoluteString,
            outputFileName: "Demo.sgmodule",
            storageLocation: .local
        )
        XCTAssertEqual(ModuleFilter.updatable.matches(module, combinedModuleEnabled: true), true)
        XCTAssertEqual(ModuleFilter.nonUpdatable.matches(module, combinedModuleEnabled: true), false)
        XCTAssertEqual(ModuleFilter.local.matches(module, combinedModuleEnabled: true), true)
        XCTAssertEqual(ModuleFilter.github.matches(module, combinedModuleEnabled: true), false)

        module = RelayModule(
            name: "Enabled",
            sourceURL: "https://example.com/test.sgmodule",
            outputFileName: "Demo",
            isEnabled: true
        )
        XCTAssertEqual(ModuleFilter.includedInCombined.matches(module, combinedModuleEnabled: true), true)
        XCTAssertEqual(ModuleFilter.excludedFromCombined.matches(module, combinedModuleEnabled: true), false)

        XCTAssertEqual(ModuleFilter.includedInCombined.matches(module, combinedModuleEnabled: false), false)
        XCTAssertEqual(ModuleFilter.excludedFromCombined.matches(module, combinedModuleEnabled: false), true)

        let counts = ModuleFilter.counts(
            for: [module],
            combinedModuleEnabled: true
        )
        XCTAssertEqual(counts[.includedInCombined], 1)
        XCTAssertEqual(counts[.excludedFromCombined], 0)
    }

    func testModuleExtendedFilterMatching() {
        let remote = RelayModule(
            name: "Remote",
            sourceURL: "https://example.com/a.sgmodule",
            outputFileName: "A",
            publishesStandalone: true
        )
        XCTAssertTrue(ModuleFilter.remoteSource.matches(remote, combinedModuleEnabled: true))
        XCTAssertTrue(ModuleFilter.standalone.matches(remote, combinedModuleEnabled: true))
        XCTAssertFalse(ModuleFilter.cachedOnly.matches(remote, combinedModuleEnabled: true))
        XCTAssertFalse(ModuleFilter.selfAuthored.matches(remote, combinedModuleEnabled: true))

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
        XCTAssertTrue(ModuleFilter.subscribed.matches(subscribed, combinedModuleEnabled: true))
        XCTAssertFalse(ModuleFilter.selfAuthored.matches(subscribed, combinedModuleEnabled: true))

        let selfAuthored = RelayModule(
            name: "Self",
            sourceURL: URL(filePath: "/tmp/self.sgmodule").absoluteString,
            outputFileName: "Self.sgmodule",
            storageLocation: .local
        )
        XCTAssertTrue(ModuleFilter.selfAuthored.matches(selfAuthored, combinedModuleEnabled: true))

        let failed = RelayModule(
            name: "Fail",
            sourceURL: "https://example.com/f.sgmodule",
            outputFileName: "F",
            state: .failed
        )
        XCTAssertTrue(ModuleFilter.failed.matches(failed, combinedModuleEnabled: true))
        XCTAssertTrue(ModuleFilter.attention.matches(failed, combinedModuleEnabled: true))

        let never = RelayModule(
            name: "Never",
            sourceURL: "https://example.com/n.sgmodule",
            outputFileName: "N",
            state: .never
        )
        XCTAssertTrue(ModuleFilter.neverUpdated.matches(never, combinedModuleEnabled: true))

        let conflict = RelayModule(
            name: "Conflict",
            sourceURL: "https://example.com/c.sgmodule",
            outputFileName: "C",
            hasOverrideConflict: true
        )
        XCTAssertTrue(ModuleFilter.overrideConflict.matches(conflict, combinedModuleEnabled: true))
        XCTAssertTrue(ModuleFilter.attention.matches(conflict, combinedModuleEnabled: true))

        let cached = RelayModule(
            name: "Cached",
            sourceURL: "https://example.com/x.sgmodule",
            outputFileName: "X",
            publishesStandalone: false
        )
        XCTAssertTrue(ModuleFilter.cachedOnly.matches(cached, combinedModuleEnabled: true))
        XCTAssertFalse(ModuleFilter.standalone.matches(cached, combinedModuleEnabled: true))

        let github = RelayModule(
            name: "GH",
            sourceURL: "https://example.com/gh.sgmodule",
            outputFileName: "GH",
            storageLocation: .gitHub
        )
        XCTAssertTrue(ModuleFilter.github.matches(github, combinedModuleEnabled: true))
        XCTAssertFalse(ModuleFilter.local.matches(github, combinedModuleEnabled: true))
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
        XCTAssertEqual(ModuleFilter.standalone.group, .behavior)
        XCTAssertEqual(ModuleFilter.includedInCombined.group, .combined)
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