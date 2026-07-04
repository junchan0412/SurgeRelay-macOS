import XCTest
@testable import SurgeRelay

final class ModuleRefreshPlannerTests: XCTestCase {
    func testRefreshEligibilityRulesStayInOnePlace() {
        let remoteDisabled = RelayModule(
            name: "Remote",
            sourceURL: "https://example.com/remote.sgmodule",
            outputFileName: "Remote",
            publishesStandalone: false,
            isEnabled: false
        )
        let localCombinedOnly = RelayModule(
            name: "Local Combined",
            sourceURL: "file:///Users/example/Surge/Local.sgmodule",
            outputFileName: "Local.sgmodule",
            publishesStandalone: false,
            isEnabled: true
        )
        let localStandalone = RelayModule(
            name: "Local Standalone",
            sourceURL: "file:///Users/example/Surge/Standalone.sgmodule",
            outputFileName: "Standalone.sgmodule",
            publishesStandalone: true,
            isEnabled: false
        )
        let localIgnored = RelayModule(
            name: "Local Ignored",
            sourceURL: "file:///Users/example/Surge/Ignored.sgmodule",
            outputFileName: "Ignored.sgmodule",
            publishesStandalone: false,
            isEnabled: false
        )

        XCTAssertTrue(ModuleRefreshPlanner.isUpdateable(remoteDisabled, combinedModuleEnabled: false))
        XCTAssertTrue(ModuleRefreshPlanner.isUpdateable(localStandalone, combinedModuleEnabled: false))
        XCTAssertTrue(ModuleRefreshPlanner.isUpdateable(localCombinedOnly, combinedModuleEnabled: true))
        XCTAssertFalse(ModuleRefreshPlanner.isUpdateable(localCombinedOnly, combinedModuleEnabled: false))
        XCTAssertFalse(ModuleRefreshPlanner.isUpdateable(localIgnored, combinedModuleEnabled: true))

        let updateableNames = ModuleRefreshPlanner.updateableModules(
            in: [remoteDisabled, localCombinedOnly, localStandalone, localIgnored],
            combinedModuleEnabled: true
        ).map(\.name)
        XCTAssertEqual(updateableNames, ["Remote", "Local Combined", "Local Standalone"])
    }

    func testLaunchUpdateRequiresMissingCacheOrDueRefresh() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let recent = RelayModule(
            name: "Recent",
            sourceURL: "https://example.com/recent.sgmodule",
            outputFileName: "Recent",
            publishesStandalone: true,
            lastUpdatedAt: now.addingTimeInterval(-30)
        )
        let old = RelayModule(
            name: "Old",
            sourceURL: "https://example.com/old.sgmodule",
            outputFileName: "Old",
            publishesStandalone: true,
            lastUpdatedAt: now.addingTimeInterval(-4_000)
        )
        let neverUpdated = RelayModule(
            name: "Never",
            sourceURL: "https://example.com/never.sgmodule",
            outputFileName: "Never",
            publishesStandalone: true,
            lastUpdatedAt: nil
        )
        let ignoredWithoutCache = RelayModule(
            name: "Ignored",
            sourceURL: "file:///Users/example/Surge/Ignored.sgmodule",
            outputFileName: "Ignored.sgmodule",
            publishesStandalone: false,
            isEnabled: false,
            lastUpdatedAt: nil
        )

        let recentCachedShouldUpdate = await ModuleRefreshPlanner.shouldUpdateOnLaunch(
            modules: [recent, ignoredWithoutCache],
            combinedModuleEnabled: false,
            refreshIntervalMinutes: 60,
            now: now,
            componentExists: { _ in true }
        )
        let missingCacheShouldUpdate = await ModuleRefreshPlanner.shouldUpdateOnLaunch(
            modules: [recent],
            combinedModuleEnabled: false,
            refreshIntervalMinutes: 60,
            now: now,
            componentExists: { _ in false }
        )
        let neverUpdatedShouldUpdate = await ModuleRefreshPlanner.shouldUpdateOnLaunch(
            modules: [neverUpdated],
            combinedModuleEnabled: false,
            refreshIntervalMinutes: 60,
            now: now,
            componentExists: { _ in true }
        )
        let oldModuleShouldUpdate = await ModuleRefreshPlanner.shouldUpdateOnLaunch(
            modules: [recent, old],
            combinedModuleEnabled: false,
            refreshIntervalMinutes: 60,
            now: now,
            componentExists: { _ in true }
        )

        XCTAssertFalse(recentCachedShouldUpdate)
        XCTAssertTrue(missingCacheShouldUpdate)
        XCTAssertTrue(neverUpdatedShouldUpdate)
        XCTAssertTrue(oldModuleShouldUpdate)
    }
}
