import Foundation

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
}
