import Foundation

/// 判定更新失败是否值得自动重试的瞬态错误（瞬时 404 / 5xx / 网络/DNS/超时）。
enum UpdateRetryPolicy {
    static func shouldRetryTransientFailure(_ error: any Error) -> Bool {
        if let relayError = error as? RelayError, case let .httpFailure(status, _) = relayError {
            return status == 404 || (500..<600).contains(status)
        }
        if error is URLError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
    }
}

struct UpdateFailureOutcomePlan: Equatable, Sendable {
    var historyEntry: UpdateHistoryEntry
}

enum UpdateFailurePlanner {
    static func shouldCheckUpdateSourceAfterConversionFailure(
        _ error: any Error,
        module: RelayModule,
        existingSourceCheckFailure: (any Error)?
    ) -> Bool {
        existingSourceCheckFailure == nil &&
            !UpdateFailureFormatter.isActionableNetworkFailure(error) &&
            module.hasRemoteUpdateSource
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
            sourceURL: current.updateSourceURL,
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
        duration: TimeInterval
    ) -> UpdateFailureOutcomePlan {
        UpdateFailureOutcomePlan(
            historyEntry: UpdateHistoryEntry(
                moduleID: module.id,
                moduleName: module.name,
                outcome: .cachedAfterFailure,
                duration: duration,
                message: failureMessage,
                usedCache: true
            )
        )
    }

    static func missingCacheFailureOutcome(
        module: RelayModule,
        failureMessage: String,
        duration: TimeInterval
    ) -> UpdateFailureOutcomePlan {
        UpdateFailureOutcomePlan(
            historyEntry: UpdateHistoryEntry(
                moduleID: module.id,
                moduleName: module.name,
                outcome: .failed,
                duration: duration,
                message: failureMessage
            )
        )
    }

}
