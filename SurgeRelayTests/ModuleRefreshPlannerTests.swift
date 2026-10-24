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


    func testLaunchUpdateRequiresMissingCacheOrDueRefresh() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let recent = RelayModule(
            name: "Recent",
            sourceURL: "https://example.com/recent.sgmodule",
            outputFileName: "Recent",
            lastUpdatedAt: now.addingTimeInterval(-30)
        )
        let old = RelayModule(
            name: "Old",
            sourceURL: "https://example.com/old.sgmodule",
            outputFileName: "Old",
            lastUpdatedAt: now.addingTimeInterval(-4_000)
        )
        let neverUpdated = RelayModule(
            name: "Never",
            sourceURL: "https://example.com/never.sgmodule",
            outputFileName: "Never",
            lastUpdatedAt: nil
        )
        let ignoredWithoutCache = RelayModule(
            name: "Ignored",
            sourceURL: "file:///Users/example/Surge/Ignored.sgmodule",
            outputFileName: "Ignored.sgmodule",
            lastUpdatedAt: nil
        )

        let newLocalShouldUpdate = await ModuleRefreshPlanner.shouldUpdateOnLaunch(
            modules: [ignoredWithoutCache], refreshIntervalMinutes: 60, now: now, componentExists: { _ in true })
        XCTAssertTrue(newLocalShouldUpdate)
        let recentCachedShouldUpdate = await ModuleRefreshPlanner.shouldUpdateOnLaunch(
            modules: [recent],
            refreshIntervalMinutes: 60,
            now: now,
            componentExists: { _ in true }
        )
        let missingCacheShouldUpdate = await ModuleRefreshPlanner.shouldUpdateOnLaunch(
            modules: [recent],
            refreshIntervalMinutes: 60,
            now: now,
            componentExists: { _ in false }
        )
        let neverUpdatedShouldUpdate = await ModuleRefreshPlanner.shouldUpdateOnLaunch(
            modules: [neverUpdated],
            refreshIntervalMinutes: 60,
            now: now,
            componentExists: { _ in true }
        )
        let oldModuleShouldUpdate = await ModuleRefreshPlanner.shouldUpdateOnLaunch(
            modules: [recent, old],
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
