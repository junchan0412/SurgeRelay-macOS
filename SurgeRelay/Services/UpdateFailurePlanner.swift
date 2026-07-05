import Foundation

struct UpdateFailureOutcomePlan: Equatable, Sendable {
    var historyEntry: UpdateHistoryEntry
    var shouldUseCachedContentInCombined: Bool
    var missingCacheModuleName: String?
    var missingCacheDetail: String?
}

struct UpdateMissingCacheBlockage: Equatable, Sendable {
    var statusMessage: String
    var presentedError: String
}

enum UpdateFailurePlanner {
    static func shouldCheckOriginalSourceAfterConversionFailure(
        _ error: any Error,
        module: RelayModule,
        existingSourceCheckFailure: (any Error)?
    ) -> Bool {
        existingSourceCheckFailure == nil &&
            !UpdateFailureFormatter.isActionableNetworkFailure(error) &&
            module.hasRemoteOriginalSource
    }

    static func detailedMessage(
        for error: any Error,
        module: RelayModule,
        latestModule: RelayModule? = nil,
        sourceCheckFailure: (any Error)? = nil
    ) -> String {
        let current = latestModule ?? module
        return UpdateFailureFormatter.detailedMessage(
            for: error,
            sourceURL: current.effectiveOriginalSourceURL,
            sourceCheckError: sourceCheckFailure
        )
    }

    static func missingCacheFailureDetail(moduleName: String, failureMessage: String) -> String {
        let indentedMessage = failureMessage.replacingOccurrences(of: "\n", with: "\n  ")
        return "- \(moduleName)：\(indentedMessage)"
    }

    static func cachedFailureOutcome(
        module: RelayModule,
        failureMessage: String,
        duration: TimeInterval,
        contributesToCombined: Bool
    ) -> UpdateFailureOutcomePlan {
        UpdateFailureOutcomePlan(
            historyEntry: UpdateHistoryEntry(
                moduleID: module.id,
                moduleName: module.name,
                outcome: .cachedAfterFailure,
                duration: duration,
                message: failureMessage,
                usedCache: true
            ),
            shouldUseCachedContentInCombined: contributesToCombined,
            missingCacheModuleName: nil,
            missingCacheDetail: nil
        )
    }

    static func missingCacheFailureOutcome(
        module: RelayModule,
        failureMessage: String,
        duration: TimeInterval,
        contributesToCombined: Bool
    ) -> UpdateFailureOutcomePlan {
        UpdateFailureOutcomePlan(
            historyEntry: UpdateHistoryEntry(
                moduleID: module.id,
                moduleName: module.name,
                outcome: .failed,
                duration: duration,
                message: failureMessage
            ),
            shouldUseCachedContentInCombined: false,
            missingCacheModuleName: contributesToCombined ? module.name : nil,
            missingCacheDetail: contributesToCombined
                ? missingCacheFailureDetail(
                    moduleName: module.name,
                    failureMessage: failureMessage
                )
                : nil
        )
    }

    static func missingCacheBlockage(
        moduleNames: [String],
        details: [String]
    ) -> UpdateMissingCacheBlockage? {
        guard !moduleNames.isEmpty else { return nil }
        let detailText = details.isEmpty ? moduleNames.joined(separator: "\n") : details.joined(separator: "\n")
        return UpdateMissingCacheBlockage(
            statusMessage: "无法重建总模块：\(moduleNames.joined(separator: "、")) 尚无可用缓存",
            presentedError: "以下来源首次转换失败，因此没有覆盖当前总模块：\n\(detailText)"
        )
    }
}
