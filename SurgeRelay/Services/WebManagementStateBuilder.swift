import Foundation

enum WebManagementStateBuilder {
    @MainActor
    static func payload(model: AppModel) -> WebStatePayload {
        let summary = model.moduleSummary
        let updateAdmission = model.updateAdmission
        return WebStatePayload(
            combined: combinedPayload(
                summary: summary,
                settings: model.settings,
                rawURL: model.combinedRawURL,
                localFileURL: model.combinedLocalFileURL
            ),
            moduleOutputFolders: model.moduleOutputFolderOptions(),
            modules: model.modules.map { module in
                modulePayload(
                    module,
                    publishedURL: model.rawURL(for: module),
                    iconURL: WebManagementAssets.iconURL(for: module)
                )
            },
            activity: activityPayload(
                isWorking: model.isWorking,
                workActivity: model.workActivity,
                statusMessage: model.statusMessage,
                completedCount: model.synchronizationCompletedCount,
                totalCount: model.synchronizationTotalCount,
                currentModuleID: model.synchronizingModuleID,
                updateAdmission: updateAdmission,
                summary: summary,
                automaticPublishScheduledAt: model.automaticPublishScheduledAt,
                automaticPublishRunsAt: model.automaticPublishRunsAt,
                latestGitHubPublish: model.latestGitHubPublish,
                error: model.presentedError,
                cancellationRequested: model.workCancellationRequested
            )
        )
    }

    static func combinedPayload(
        summary: ModuleCollectionSummary,
        settings: AppSettings,
        rawURL: URL?,
        localFileURL: URL?
    ) -> WebCombinedPayload {
        let isEnabled = settings.combinedModuleEnabled
        return WebCombinedPayload(
            name: "Surge Relay 汇总",
            isEnabled: isEnabled,
            fileName: FilenameSanitizer.sgmoduleName(from: settings.combinedModuleFileName),
            sourceCount: summary.totalCount,
            enabledCount: isEnabled ? summary.enabledCount : 0,
            lastUpdatedAt: summary.latestUpdatedAt,
            subscriptionURL: isEnabled
                ? rawURL?.absoluteString ?? localFileURL?.absoluteString
                : nil
        )
    }

    static func modulePayload(
        _ module: RelayModule,
        publishedURL: URL?,
        iconURL: String?
    ) -> WebModulePayload {
        WebModulePayload(
            id: module.id.uuidString.lowercased(),
            name: module.name,
            sourceURL: module.sourceURL,
            effectiveOriginalSourceURL: module.effectiveOriginalSourceURL,
            sourceFormat: module.sourceFormat.rawValue,
            sourceFormatTitle: module.sourceFormatDisplayTitle,
            sourceOriginTitle: module.sourceOrigin.title,
            sourceOriginIcon: module.sourceOrigin.systemImage,
            outputFileName: module.outputFileName,
            publishedRelativePath: module.publishedRelativePath,
            category: module.category,
            outputFolder: module.outputFolder,
            storageLocation: module.storageLocation.rawValue,
            storageLocationTitle: module.displayStorageLocationTitle,
            storageLocationDetail: module.standaloneStorageDetail,
            storageLocationIcon: module.displayStorageLocationSystemImage,
            relationshipSummary: module.relationshipSummary,
            localStorageRelativePath: module.localStorageRelativePath,
            publishesStandalone: module.publishesStandalone,
            isEnabled: module.isEnabled,
            state: module.state.rawValue,
            stateTitle: module.state.title,
            createdAt: module.createdAt,
            lastUpdatedAt: module.lastUpdatedAt,
            sourceCheckedAt: module.sourceCheckedAt,
            contentHash: module.contentHash,
            sourceETag: module.sourceETag,
            sourceLastModified: module.sourceLastModified,
            sourceContentHash: module.sourceContentHash,
            conversionEngineRevision: module.conversionEngineRevision,
            lastError: module.lastError,
            iconURL: iconURL,
            customIconURL: module.customIconURL,
            publishedURL: publishedURL?.absoluteString,
            advancedSummary: module.scriptHubOptions.configuredSummary,
            hasOverrideConflict: module.hasOverrideConflict,
            scriptHubOptions: module.scriptHubOptions,
            policy: module.scriptHubOptions.policy,
            includeKeywords: module.scriptHubOptions.includeKeywords,
            excludeKeywords: module.scriptHubOptions.excludeKeywords,
            mitmAdd: module.scriptHubOptions.mitmAdd,
            mitmRemove: module.scriptHubOptions.mitmRemove,
            noResolve: module.scriptHubOptions.noResolve,
            enableJQ: module.scriptHubOptions.enableJQ
        )
    }

    static func activityPayload(
        isWorking: Bool,
        workActivity: WorkActivity,
        statusMessage: String,
        completedCount: Int,
        totalCount: Int,
        currentModuleID: UUID?,
        updateAdmission: UpdateAdmission,
        summary: ModuleCollectionSummary,
        automaticPublishScheduledAt: Date?,
        automaticPublishRunsAt: Date?,
        latestGitHubPublish: GitHubPublishSnapshot?,
        error: String?,
        cancellationRequested: Bool
    ) -> WebActivityPayload {
        WebActivityPayload(
            isWorking: isWorking,
            kind: workActivity.kind.rawValue,
            title: workActivity.isActive ? workActivity.title : nil,
            status: statusMessage,
            progress: progress(completedCount: completedCount, totalCount: totalCount),
            currentModuleID: currentModuleID?.uuidString.lowercased(),
            startedAt: workActivity.startedAt,
            blocksUpdates: workActivity.blocksUpdates,
            canCancel: workActivity.canCancel,
            cancellationRequested: cancellationRequested,
            canStartUpdate: updateAdmission.isAccepted,
            updateBlockedReason: updateAdmission.blockedReason,
            enabledModuleCount: summary.updateableCount,
            automaticPublishScheduledAt: automaticPublishScheduledAt,
            automaticPublishRunsAt: automaticPublishRunsAt,
            latestGitHubPublish: latestGitHubPublish,
            error: error
        )
    }

    static func progress(completedCount: Int, totalCount: Int) -> Double? {
        guard totalCount > 0 else { return nil }
        return min(max(Double(completedCount) / Double(totalCount), 0), 1)
    }
}
