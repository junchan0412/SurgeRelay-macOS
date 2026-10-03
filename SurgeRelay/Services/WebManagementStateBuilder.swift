import Foundation

enum WebManagementStateBuilder {
    static func payload(snapshot: WebCoreSnapshot, activity: WebActivityPayload, summary: ModuleCollectionSummary, modules: [WebModulePayload]) -> WebStatePayload {
        let settings = snapshot.settings
        return WebStatePayload(
            combined: combinedPayload(summary: summary, settings: settings,
                rawURL: PublishedAddressResolver.combinedGitHubURL(settings: settings),
                localFileURL: PublishedAddressResolver.combinedLocalFileURL(settings: settings)),
            moduleEditor: moduleEditorPayload(settings: settings,
                localOutputFolders: ModuleOutputFolderCatalog.options(settings: settings, modules: snapshot.modules,
                    localFolders: snapshot.localFolders, githubFolders: snapshot.githubFolders, storageLocation: .local),
                githubOutputFolders: ModuleOutputFolderCatalog.options(settings: settings, modules: snapshot.modules,
                    localFolders: snapshot.localFolders, githubFolders: snapshot.githubFolders, storageLocation: .gitHub)),
            modules: modules,
            activity: activity, runtimeID: snapshot.runtimeID, revision: snapshot.revision,
            workspace: WebWorkspacePayload(localDirectory: settings.localModuleDirectory,
                githubRepository: settings.github.isConfigured ? "\(settings.github.owner)/\(settings.github.repository)" : "",
                githubBranch: settings.github.branch, historyCount: snapshot.historyCount,
                recentHistory: snapshot.recentHistory, id: snapshot.workspaceID,
                name: snapshot.workspaceName, isLegacyDefault: snapshot.isLegacyWorkspace))
    }

    static func moduleProjection(snapshot: WebCoreSnapshot) throws -> [WebModulePayload] {
        try snapshot.modules.map { module in
            try Task.checkCancellation()
            return modulePayload(module,
                publishedURL: PublishedAddressResolver.standaloneURL(for: module, settings: snapshot.settings),
                iconURL: WebManagementAssets.iconURL(for: module, cacheDirectory: snapshot.cacheDirectory))
        }
    }

    static func activityPayload(snapshot: WebActivitySnapshot, core: WebCoreSnapshot, summary: ModuleCollectionSummary) -> WebActivityPayload {
        let admission = UpdateAdmission.allModules(activity: snapshot.workActivity,
            updateableModuleCount: summary.updateableCount, statusMessage: snapshot.statusMessage)
        let currentModuleID = snapshot.synchronizingModuleIDs.isEmpty ? nil
            : core.modules.first { snapshot.synchronizingModuleIDs.contains($0.id) }?.id
        return activityPayload(isWorking: snapshot.isWorking, workActivity: snapshot.workActivity,
            statusMessage: snapshot.statusMessage, completedCount: snapshot.completedCount, totalCount: snapshot.totalCount,
            currentModuleID: currentModuleID, updateAdmission: admission, summary: summary,
            automaticPublishScheduledAt: snapshot.automaticPublishScheduledAt,
            automaticPublishRunsAt: snapshot.automaticPublishRunsAt,
            latestGitHubPublish: GitHubPublishSnapshot.latest(in: snapshot.history, settings: snapshot.githubSettings),
            error: snapshot.error, cancellationRequested: snapshot.cancellationRequested)
    }

    static func moduleEditorPayload(
        settings: AppSettings,
        localOutputFolders: [String],
        githubOutputFolders: [String]
    ) -> WebModuleEditorPayload {
        WebModuleEditorPayload(
            defaultStorageLocation: ModuleStorageLocation.preferredDefault(
                publishToLocal: settings.publishToLocal
            ).rawValue,
            localOutputFolders: localOutputFolders,
            githubOutputFolders: githubOutputFolders,
            publishToLocal: settings.publishToLocal,
            publishToGitHub: settings.publishToGitHub
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
            initialSourceURL: module.initialSourceURL,
            updateSourceURL: module.updateSourceURL,
            sourceFormat: module.sourceFormat.rawValue,
            sourceFormatTitle: module.sourceFormatDisplayTitle,
            initialSourceTitle: module.initialSource.title,
            initialSourceIcon: module.initialSource.systemImage,
            outputFileName: module.outputFileName,
            publishedRelativePath: module.publishedRelativePath,
            category: module.category,
            outputFolder: module.outputFolder,
            storageLocation: module.storageLocation.rawValue,
            storageTargets: module.storageTargets.map(\.rawValue).sorted(),
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
            refreshIntervalMinutes: module.refreshIntervalMinutes,
            nextRetryAt: module.nextRetryAt,
            serverRetryAfter: module.serverRetryAfter,
            consecutiveFailureCount: module.consecutiveFailureCount,
            conversionEngineRevision: module.conversionEngineRevision,
            lastError: module.lastError,
            iconURL: iconURL,
            customIconURL: module.customIconURL,
            publishedURL: publishedURL?.absoluteString,
            advancedSummary: module.scriptHubOptions.configuredSummary,
            hasOverrideConflict: module.hasOverrideConflict,
            hasSyncConflict: module.hasSyncConflict,
            syncConflictLocalUpdatedAt: module.syncConflict?.localUpdatedAt,
            syncConflictGitHubUpdatedAt: module.syncConflict?.githubUpdatedAt,
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
            completedCount: totalCount > 0 ? completedCount : nil,
            totalCount: totalCount > 0 ? totalCount : nil,
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
            error: error,
            activeStages: workActivity.activeStages
        )
    }

    static func progress(completedCount: Int, totalCount: Int) -> Double? {
        guard totalCount > 0 else { return nil }
        return min(max(Double(completedCount) / Double(totalCount), 0), 1)
    }
}
