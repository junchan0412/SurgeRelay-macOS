import Foundation

struct AutomaticPublishContext: Equatable, Sendable {
    var publishToGitHub: Bool
    var automaticallyPublish: Bool
    var gitHubConfigured: Bool
    var tokenAvailable: Bool

    var isConfigured: Bool {
        publishToGitHub && automaticallyPublish && gitHubConfigured
    }

    var canUseAutomaticPublishing: Bool {
        isConfigured && tokenAvailable
    }
}

struct AutomaticPublishAdmission: Equatable, Sendable {
    var isAccepted: Bool
    var shouldClearSchedule: Bool
    var statusMessage: String?

    static let accepted = AutomaticPublishAdmission(
        isAccepted: true,
        shouldClearSchedule: false,
        statusMessage: nil
    )

    static func rejected(statusMessage: String? = nil) -> AutomaticPublishAdmission {
        AutomaticPublishAdmission(
            isAccepted: false,
            shouldClearSchedule: true,
            statusMessage: statusMessage
        )
    }
}

enum AutomaticPublishPlanner {
    static let noStandaloneModulesStatus = "没有开启独立发布的模块，已跳过 GitHub 自动发布"
    static let noStandaloneFilesStatus = "没有可自动发布的独立模块文件，已跳过 GitHub 自动发布"

    static func context(settings: AppSettings, tokenIsAvailable: Bool) -> AutomaticPublishContext {
        AutomaticPublishContext(
            publishToGitHub: settings.publishToGitHub,
            automaticallyPublish: settings.automaticallyPublish,
            gitHubConfigured: settings.github.isConfigured,
            tokenAvailable: tokenIsAvailable
        )
    }

    static func canUseAutomaticPublishing(context: AutomaticPublishContext) -> Bool {
        context.canUseAutomaticPublishing
    }

    static func scheduleAdmission(
        context: AutomaticPublishContext,
        plan: PublishPlan
    ) -> AutomaticPublishAdmission {
        guard context.canUseAutomaticPublishing else { return .rejected() }
        guard shouldRunScheduledPublish(plan: plan) else { return .rejected() }
        return .accepted
    }

    static func runAdmission(
        context: AutomaticPublishContext,
        plan: PublishPlan,
        hasCachedStandaloneOutput: Bool
    ) -> AutomaticPublishAdmission {
        guard context.canUseAutomaticPublishing else { return .rejected() }
        guard shouldRunScheduledPublish(plan: plan) else {
            return .rejected(statusMessage: noStandaloneModulesStatus)
        }
        guard hasCachedStandaloneOutput else {
            return .rejected(statusMessage: noStandaloneFilesStatus)
        }
        return .accepted
    }

    static func shouldQueueAfterModuleUpdate(plan: PublishPlan, contentChanged: Bool) -> Bool {
        contentChanged && shouldRunScheduledPublish(plan: plan)
    }

    static func shouldRunScheduledPublish(plan: PublishPlan) -> Bool {
        plan.hasStandaloneModuleSelection
    }

    static func skippedAfterModuleUpdateStatus(contentChanged: Bool, failures: Int) -> String {
        let failureSuffix = failures > 0 ? "；\(failures) 个来源沿用上次成功版本" : ""
        if contentChanged {
            return "模块输出已更新\(failureSuffix)；没有开启独立发布的模块，已跳过 GitHub 自动发布"
        }
        return "模块内容未变化\(failureSuffix)；没有开启独立发布的模块，无需 GitHub 自动发布"
    }

    static func hasAnyCachedStandaloneOutput(
        plan: PublishPlan,
        componentExists: @Sendable (UUID) async -> Bool
    ) async -> Bool {
        for module in plan.standaloneModules {
            if await componentExists(module.id) {
                return true
            }
        }
        return false
    }
}
