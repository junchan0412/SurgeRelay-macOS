import Foundation

@MainActor
extension AppModel {
    func prepareForWorkspaceSwitch(timeout: Duration = .seconds(10)) async throws {
        guard workspaceIsActive, !isWorkspaceTransitioning else { throw PreviewContentSaveError.busy }
        guard !workActivity.isActive || workActivity.canCancel else {
            throw RelayError.invalidOutput("当前任务已进入不可取消阶段，完成后才能切换工作区。")
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let pendingStartup = startupTask
        let pendingForeground = foregroundWorkTask
        let pendingPreparation = updatePreparationTask
        let pendingUpdate = moduleUpdateTask
        let pendingAutomaticUpdate = automaticUpdateTask
        let pendingAutomaticPublish = automaticPublishTask
        let pendingScheduler = schedulerTask
        let pendingWatcher = localSourceWatcherTask
        let pendingLocalSync = localSourceSyncTask
        isWorkspaceTransitioning = true
        if workActivity.isActive { _ = cancelCurrentWork() }
        isWorking = true
        workCancellationRequested = true
        schedulerTask?.cancel()
        automaticUpdateTask?.cancel()
        cancelAutomaticPublishSchedule()
        automaticPublishTask?.cancel()
        startupTask?.cancel()
        stopLocalSourceWatching()
        networkPathMonitor.onBecameReachable = nil
        webServer.stop()
        webServerState = .stopped
        webActionTickets.removeAll()
        pendingPublishPreview = nil
        pendingSelectedPublishLintReview = nil
        stageProgressTask?.cancel()
        activeStageProgress.removeAll()
        workActivity.activeStages = nil
        let completion = WorkspaceJoinCompletion()
        let observer = Task { @MainActor in
            await pendingStartup?.value
            await pendingForeground?.value
            await pendingPreparation?.value
            _ = await pendingUpdate?.value
            await pendingAutomaticUpdate?.value
            await pendingAutomaticPublish?.value
            await pendingScheduler?.value
            await pendingWatcher?.value
            await pendingLocalSync?.value
            completion.finished = true
        }
        defer { observer.cancel() }
        while !completion.finished || workActivity.isActive {
            guard ContinuousClock.now < deadline else {
                throw RelayError.invalidOutput("旧任务尚未完成取消；当前工作区仍保留，请稍后重试。")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        beginWork(.switchingWorkspace)
        workCancellationRequested = true
        previewDraftPersistenceTask?.cancel()
        try persistModulesIfNeeded(force: true)
        enqueueConfiguration(settings, fileName: "settings.json")
        enqueueConfiguration(upstreamState, fileName: "script-hub-state.json")
        enqueueConfiguration(Array(updateHistory.prefix(200)), fileName: "update-history.json")
        if let selectedPublishAttempt { enqueueConfiguration(selectedPublishAttempt, fileName: "selected-publish.json") }
        await flushPreviewDrafts()
        if let previewDraftPersistenceError { throw RelayError.invalidOutput(previewDraftPersistenceError) }
        try await flushPersistence()
        await fileStore.versionHistoryBarrier()
    }

    func finishWorkspaceRetirement() {
        workspaceIsActive = false
        networkPathMonitor.cancel()
        persistenceFeedbackTask?.cancel()
        stageProgressTask?.cancel()
        activeStageProgress.removeAll()
        workActivity = .idle
        isWorking = true
        githubToken = ""
        webAccessToken = ""
    }

    func resumeAfterWorkspaceSwitchFailure() {
        isWorkspaceTransitioning = false
        if workActivity.kind == .switchingWorkspace { endWork(.switchingWorkspace) }
        else if !workActivity.isActive { isWorking = false; workCancellationRequested = false }
        guard hasStarted, !AppRuntimeOptions.isUIQAMode else { return }
        applyWebServerSettings(persist: false)
        startNetworkRecoveryMonitor()
        restartScheduler()
        refreshLocalSourceWatching()
    }
}

@MainActor
private final class WorkspaceJoinCompletion {
    var finished = false
}
