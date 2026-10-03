import Foundation

enum ModuleRefreshTrigger: Equatable, Sendable {
    case manual
    case scheduled
    case launch
}

enum ModuleRefreshPlanner {
    static func contributesToCombined(
        _ module: RelayModule,
        combinedModuleEnabled: Bool
    ) -> Bool {
        combinedModuleEnabled && module.isIncludedInCombined
    }

    static func combinedContributorModules(
        in modules: [RelayModule],
        combinedModuleEnabled: Bool
    ) -> [RelayModule] {
        modules.filter {
            contributesToCombined($0, combinedModuleEnabled: combinedModuleEnabled)
        }
    }

    static func isUpdateable(
        _ module: RelayModule,
        combinedModuleEnabled: Bool
    ) -> Bool {
        module.hasRemoteUpdateSource ||
            contributesToCombined(module, combinedModuleEnabled: combinedModuleEnabled) ||
            module.publishesStandalone
    }

    static func updateableModules(
        in modules: [RelayModule],
        combinedModuleEnabled: Bool
    ) -> [RelayModule] {
        modules.filter {
            isUpdateable($0, combinedModuleEnabled: combinedModuleEnabled)
        }
    }

    static func serverDeadline(for module: RelayModule, among modules: [RelayModule]) -> Date? {
        let shared = modules.compactMap { other -> Date? in
            guard let source = other.serverRetrySourceURL,
                  ModuleSourceIdentity.matches(source, module.updateSourceURL) else { return nil }
            return other.serverRetryAfter
        }.max()
        return [module.serverRetryAfter, shared].compactMap { $0 }.max()
    }

    static func nextDueDate(for module: RelayModule, among modules: [RelayModule], globalIntervalMinutes: Int, now: Date = .now) -> Date? {
        let interval = module.refreshIntervalMinutes ?? globalIntervalMinutes
        guard interval > 0 else { return nil }
        let base: Date
        if module.consecutiveFailureCount > 0, let retry = module.nextRetryAt {
            base = retry
        } else {
            let lastCheck = module.lastRefreshAttemptAt ?? module.sourceCheckedAt ?? module.lastUpdatedAt ?? module.createdAt
            base = lastCheck.addingTimeInterval(TimeInterval(interval) * 60)
        }
        return max(base, serverDeadline(for: module, among: modules) ?? .distantPast)
    }

    static func shouldRefresh(_ module: RelayModule, among modules: [RelayModule], trigger: ModuleRefreshTrigger,
                              globalIntervalMinutes: Int, hasCache: Bool = true, now: Date = .now) -> Bool {
        if let server = serverDeadline(for: module, among: modules), server > now { return false }
        if trigger == .manual { return true }
        if module.refreshIntervalMinutes == 0 { return false }
        if let retry = module.nextRetryAt, retry > now { return false }
        if trigger == .launch, module.lastUpdatedAt == nil || !hasCache { return true }
        return nextDueDate(for: module, among: modules, globalIntervalMinutes: globalIntervalMinutes, now: now).map { $0 <= now } ?? false
    }

    static func clearFailureState(_ module: inout RelayModule) {
        module.consecutiveFailureCount = 0
        module.nextRetryAt = nil
        module.serverRetryAfter = nil
        module.serverRetrySourceURL = nil
    }

    static func recordFailure(_ module: inout RelayModule, error: (any Error)? = nil, now: Date = .now) {
        module.consecutiveFailureCount = min(module.consecutiveFailureCount, 29) + 1
        let delay = min(60 * pow(2, Double(min(module.consecutiveFailureCount - 1, 6))), 3_600)
        module.nextRetryAt = now.addingTimeInterval(delay)
        module.serverRetryAfter = nil
        module.serverRetrySourceURL = nil
        if let response = error as? SourceRetryAfterError {
            module.serverRetryAfter = response.retryAt
            module.serverRetrySourceURL = response.sourceURL
            module.nextRetryAt = max(module.nextRetryAt!, response.retryAt)
        }
    }

    static func intervalTitle(_ interval: Int?) -> String {
        guard let interval else { return "继承全局" }
        return interval == 0 ? "仅手动刷新" : "每 \(interval) 分钟"
    }

    static func shouldUpdateOnLaunch(
        modules: [RelayModule],
        combinedModuleEnabled: Bool,
        refreshIntervalMinutes: Int,
        now: Date = .now,
        componentExists: @Sendable (UUID) async -> Bool
    ) async -> Bool {
        let cooldowns = modules.filter { $0.serverRetryAfter.map { $0 > now } ?? false }
        for module in updateableModules(in: modules, combinedModuleEnabled: combinedModuleEnabled) {
            let hasCache = await componentExists(module.id)
            if shouldRefresh(module, among: cooldowns, trigger: .launch, globalIntervalMinutes: refreshIntervalMinutes,
                             hasCache: hasCache, now: now) { return true }
        }
        return false
    }
}
