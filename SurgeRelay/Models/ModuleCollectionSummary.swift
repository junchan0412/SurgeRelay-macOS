import Foundation

struct ModuleCollectionSummary: Equatable, Sendable {
    var totalCount = 0
    var enabledCount = 0
    var standaloneCount = 0
    var failedCount = 0
    var overrideConflictCount = 0
    var updateableCount = 0
    var latestUpdatedAt: Date?

    var attentionCount: Int {
        failedCount + overrideConflictCount
    }

    var hasFailures: Bool {
        failedCount > 0
    }

    init(
        modules: [RelayModule],
        isUpdateable: (RelayModule) -> Bool
    ) {
        for module in modules {
            totalCount += 1
            if module.isEnabled { enabledCount += 1 }
            if module.publishesStandalone { standaloneCount += 1 }
            if module.state == .failed { failedCount += 1 }
            if module.hasOverrideConflict { overrideConflictCount += 1 }
            if isUpdateable(module) { updateableCount += 1 }
            if let lastUpdatedAt = module.lastUpdatedAt {
                if let currentLatest = latestUpdatedAt {
                    if lastUpdatedAt > currentLatest { latestUpdatedAt = lastUpdatedAt }
                } else {
                    latestUpdatedAt = lastUpdatedAt
                }
            }
        }
    }
}
