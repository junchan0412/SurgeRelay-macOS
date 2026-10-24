import Foundation

struct ModuleUpdateRunResult {
    var moduleIDs: Set<UUID>
    var failures: Int
    var contentChanged: Bool
}

@MainActor
extension AppModel {
    @discardableResult
    func finishModuleUpdateRun(
        _ result: ModuleUpdateRunResult,
        generation: Int
    ) async -> Bool {
        let outputSucceeded = await refreshModuleOutputs(moduleIDs: result.moduleIDs, schedulesAutomaticPublish: false)
        guard shouldContinueCurrentWork(generation: generation) else { return false }
        await cleanupLegacyOutputFiles()
        guard shouldContinueCurrentWork(generation: generation) else { return false }
        let canUseAutomaticGitHubPublish = AutomaticPublishPlanner.canUseAutomaticPublishing(
            context: automaticPublishContext()
        )
        let pendingLocalCleanupFileCount = pendingPublishPreview?.destination == .local
            ? pendingPublishPreview?.deletedFiles.count
            : nil
        let completionDecision = UpdateCompletionStatusPlanner.decision(
            canUseAutomaticGitHubPublish: canUseAutomaticGitHubPublish,
            publishPlan: githubPublishPlan,
            contentChanged: result.contentChanged,
            failures: result.failures + (outputSucceeded ? 0 : 1),
            pendingLocalCleanupFileCount: pendingLocalCleanupFileCount
        )
        switch completionDecision.scheduleAction {
        case .none:
            break
        case .scheduleAutomaticPublish:
            scheduleAutomaticPublish()
        case .clearAutomaticPublishSchedule:
            clearAutomaticPublishSchedule()
        }
        statusMessage = outputSucceeded ? completionDecision.statusMessage
            : "模块已分别处理；本地输出失败的模块请查看“需要处理”"
        return outputSucceeded

    }
}
