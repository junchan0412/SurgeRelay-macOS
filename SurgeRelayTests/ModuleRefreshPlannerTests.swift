import XCTest
@testable import SurgeRelay

final class ModuleRefreshPlannerTests: XCTestCase {
    func testPerModuleIntervalsAndManualRefreshHaveSeparateDueRules() {
        let now = Date(timeIntervalSince1970: 20_000)
        let fast = RelayModule(name: "Fast", sourceURL: "https://example.com/fast", outputFileName: "Fast",
                               lastUpdatedAt: now.addingTimeInterval(-600), refreshIntervalMinutes: 5,
                               lastRefreshAttemptAt: now.addingTimeInterval(-600))
        var slow = fast
        slow.id = UUID()
        slow.refreshIntervalMinutes = nil
        let modules = [fast, slow]
        XCTAssertTrue(ModuleRefreshPlanner.shouldRefresh(fast, among: modules, trigger: .scheduled, globalIntervalMinutes: 60, now: now))
        XCTAssertFalse(ModuleRefreshPlanner.shouldRefresh(slow, among: modules, trigger: .scheduled, globalIntervalMinutes: 60, now: now))
        XCTAssertTrue(ModuleRefreshPlanner.shouldRefresh(slow, among: modules, trigger: .manual, globalIntervalMinutes: 60, now: now))
        XCTAssertTrue(ModuleRefreshPlanner.shouldRefresh(fast, among: modules, trigger: .scheduled, globalIntervalMinutes: 0, now: now))
        slow.refreshIntervalMinutes = 0
        XCTAssertNil(ModuleRefreshPlanner.nextDueDate(for: slow, among: modules, globalIntervalMinutes: 60, now: now))
    }

    func testFailureBackoffIsBoundedAndManualRefreshStillRespectsServerDeadline() throws {
        let now = Date(timeIntervalSince1970: 20_000)
        var module = RelayModule(name: "Retry", sourceURL: "https://example.com/source", outputFileName: "Retry")
        ModuleRefreshPlanner.recordFailure(&module, now: now)
        XCTAssertEqual(module.consecutiveFailureCount, 1)
        XCTAssertEqual(module.nextRetryAt, now.addingTimeInterval(60))
        XCTAssertFalse(ModuleRefreshPlanner.shouldRefresh(module, among: [module], trigger: .scheduled, globalIntervalMinutes: 60, now: now))
        XCTAssertTrue(ModuleRefreshPlanner.shouldRefresh(module, among: [module], trigger: .manual, globalIntervalMinutes: 60, now: now))
        for _ in 0..<12 { ModuleRefreshPlanner.recordFailure(&module, now: now) }
        XCTAssertEqual(module.nextRetryAt, now.addingTimeInterval(3_600))
        let response = SourceRetryAfterError(statusCode: 429, sourceURL: module.updateSourceURL, responseURL: nil, retryAt: now.addingTimeInterval(7_200))
        ModuleRefreshPlanner.recordFailure(&module, error: response, now: now)
        XCTAssertEqual(module.nextRetryAt, response.retryAt)
        XCTAssertFalse(ModuleRefreshPlanner.shouldRefresh(module, among: [module], trigger: .manual, globalIntervalMinutes: 60, now: now))
        XCTAssertTrue(ModuleRefreshPlanner.shouldRefresh(module, among: [module], trigger: .manual, globalIntervalMinutes: 60, now: response.retryAt))
        let encoded = try JSONEncoder().encode(module)
        let restored = try JSONDecoder().decode(RelayModule.self, from: encoded)
        XCTAssertEqual(restored.nextRetryAt, response.retryAt)
        XCTAssertEqual(restored.consecutiveFailureCount, module.consecutiveFailureCount)
        ModuleRefreshPlanner.clearFailureState(&module)
        XCTAssertEqual(module.consecutiveFailureCount, 0)
        XCTAssertNil(module.serverRetryAfter)
        XCTAssertNil(module.nextRetryAt)
    }

    func testServerCooldownMatchesOnlyActualSourceAndNotOtherURLsOnHost() {
        let deadline = Date(timeIntervalSince1970: 50_000)
        let limited = RelayModule(name: "Limited", sourceURL: "https://example.com/a", outputFileName: "A",
                                  serverRetryAfter: deadline, serverRetrySourceURL: "https://example.com/a")
        let same = RelayModule(name: "Same", sourceURL: "https://EXAMPLE.com:443/a#fragment", outputFileName: "Same")
        let unrelated = RelayModule(name: "Unrelated", sourceURL: "https://example.com/b", outputFileName: "B")
        XCTAssertEqual(ModuleRefreshPlanner.serverDeadline(for: same, among: [limited, same, unrelated]), deadline)
        XCTAssertNil(ModuleRefreshPlanner.serverDeadline(for: unrelated, among: [limited, same, unrelated]))
    }

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

        XCTAssertEqual(
            ModuleRefreshPlanner.combinedContributorModules(
                in: [remoteDisabled, localCombinedOnly, localStandalone, localIgnored],
                combinedModuleEnabled: true
            ).map(\.name),
            ["Local Combined"]
        )
        XCTAssertTrue(ModuleRefreshPlanner.combinedContributorModules(
            in: [remoteDisabled, localCombinedOnly, localStandalone, localIgnored],
            combinedModuleEnabled: false
        ).isEmpty)

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
