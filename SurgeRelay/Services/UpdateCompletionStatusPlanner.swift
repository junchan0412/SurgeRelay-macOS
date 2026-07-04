import Foundation

enum UpdateCompletionScheduleAction: Equatable, Sendable {
    case none
    case scheduleAutomaticPublish
    case clearAutomaticPublishSchedule
}

struct UpdateCompletionDecision: Equatable, Sendable {
    var scheduleAction: UpdateCompletionScheduleAction
    var statusMessage: String
}

enum UpdateCompletionStatusPlanner {
    static func decision(
        canUseAutomaticGitHubPublish: Bool,
        publishPlan: PublishPlan,
        contentChanged: Bool,
        failures: Int,
        pendingLocalCleanupFileCount: Int?,
        combinedModuleEnabled: Bool,
        combinedSourceCount: Int
    ) -> UpdateCompletionDecision {
        if canUseAutomaticGitHubPublish {
            if AutomaticPublishPlanner.shouldRunScheduledPublish(plan: publishPlan) {
                return UpdateCompletionDecision(
                    scheduleAction: AutomaticPublishPlanner.shouldQueueAfterModuleUpdate(
                        plan: publishPlan,
                        contentChanged: contentChanged
                    ) ? .scheduleAutomaticPublish : .none,
                    statusMessage: automaticPublishQueuedStatus(
                        contentChanged: contentChanged,
                        failures: failures
                    )
                )
            }
            return UpdateCompletionDecision(
                scheduleAction: .clearAutomaticPublishSchedule,
                statusMessage: AutomaticPublishPlanner.skippedAfterModuleUpdateStatus(
                    contentChanged: contentChanged,
                    failures: failures
                )
            )
        }

        if let staleFileCount = pendingLocalCleanupFileCount {
            return UpdateCompletionDecision(
                scheduleAction: .none,
                statusMessage: localCleanupPendingStatus(
                    failures: failures,
                    staleFileCount: staleFileCount
                )
            )
        }

        return UpdateCompletionDecision(
            scheduleAction: .none,
            statusMessage: refreshedOutputStatus(
                combinedModuleEnabled: combinedModuleEnabled,
                combinedSourceCount: combinedSourceCount,
                failures: failures
            )
        )
    }

    static func automaticPublishQueuedStatus(contentChanged: Bool, failures: Int) -> String {
        if contentChanged {
            return failures == 0
                ? "模块输出已更新，等待发布"
                : "模块输出已更新；\(failures) 个来源沿用上次版本，等待发布"
        }
        return failures == 0
            ? "所有模块内容均未变化，无需发布"
            : "模块内容未变化；\(failures) 个来源沿用上次版本，无需发布"
    }

    static func localCleanupPendingStatus(failures: Int, staleFileCount: Int) -> String {
        failures == 0
            ? "模块输出已更新，等待确认清理 \(staleFileCount) 个本地旧文件"
            : "模块输出已更新；\(failures) 个来源沿用上次版本，等待确认清理 \(staleFileCount) 个本地旧文件"
    }

    static func refreshedOutputStatus(
        combinedModuleEnabled: Bool,
        combinedSourceCount: Int,
        failures: Int
    ) -> String {
        if combinedModuleEnabled {
            return failures == 0
                ? "总模块已由 \(combinedSourceCount) 个来源合并完成"
                : "总模块已更新；\(failures) 个来源沿用上次成功版本"
        }
        return failures == 0
            ? "模块输出已刷新"
            : "模块输出已刷新；\(failures) 个来源沿用上次成功版本"
    }
}
