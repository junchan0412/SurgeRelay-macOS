import Foundation

struct ModuleUpdateRunResult {
    var components: [(RelayModule, String)]
    var failures: Int
    var missingCacheModuleNames: [String]
    var missingCacheDetails: [String]
    var contentChanged: Bool
}

@MainActor
extension AppModel {
    func finishModuleUpdateRun(
        _ result: ModuleUpdateRunResult,
        generation: Int,
        rebuildFromCache: Bool = false
    ) async {
        if let blockage = UpdateFailurePlanner.missingCacheBlockage(
            moduleNames: result.missingCacheModuleNames,
            details: result.missingCacheDetails
        ) {
            statusMessage = blockage.statusMessage
            presentedError = blockage.presentedError
            return
        }

        do {
            if rebuildFromCache {
                // 单模块（过滤）更新：从全部缓存组件重建总模块并发布本地输出，
                // 避免总模块只包含被更新模块而丢失其他参与者。
                await rebuildCombinedFromCache()
            } else if settings.combinedModuleEnabled {
                try await writeCombinedModule(result.components)
            } else {
                try? await fileStore.removeCombined()
                try await publishCurrentFiles(combinedData: nil, includeAssets: false)
            }
            guard shouldContinueCurrentWork(generation: generation) else { return }
            await cleanupLegacyOutputFiles()
            guard shouldContinueCurrentWork(generation: generation) else { return }
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
                failures: result.failures,
                pendingLocalCleanupFileCount: pendingLocalCleanupFileCount,
                combinedModuleEnabled: settings.combinedModuleEnabled,
                combinedSourceCount: result.components.count
            )
            switch completionDecision.scheduleAction {
            case .none:
                break
            case .scheduleAutomaticPublish:
                scheduleAutomaticPublish()
            case .clearAutomaticPublishSchedule:
                clearAutomaticPublishSchedule()
            }
            statusMessage = completionDecision.statusMessage
        } catch {
            if isCurrentWorkCancellation(error) { return }
            presentedError = settings.combinedModuleEnabled
                ? "合并失败，当前总模块未被覆盖：\(error.localizedDescription)"
                : "刷新模块输出失败：\(error.localizedDescription)"
        }
    }
}
