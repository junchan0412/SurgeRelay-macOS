import Foundation

@MainActor
extension AppModel {
    func publishAll() async {
        guard !isWorking else { return }
        cancelAutomaticPublishSchedule()
        do {
            let payload = try await webPublishPreview(WebPublishPreviewRequest(scope: "githubAll"), retainsForNativeUI: true)
            guard let preview = payload.previews.first else { throw RelayError.noFilesToPublish }
            if preview.requiresDeletionConfirmation || !preview.issues.isEmpty {
                retainNativePublishPreview(payload)
            } else {
                _ = try await confirmWebPublish(token: payload.token)
            }
        } catch { presentPublishReviewError(error) }
    }

    func publishModules(moduleIDs: Set<UUID>) async -> Bool {
        await reviewSelectedPublish(WebPublishPreviewRequest(moduleIDs: moduleIDs))
    }

    func retrySelectedPublish() async {
        guard let attempt = selectedPublishAttempt, !attempt.retryDestinations.isEmpty else { return }
        _ = await reviewSelectedPublish(WebPublishPreviewRequest(retryAttemptID: attempt.id))
    }

    private func reviewSelectedPublish(_ request: WebPublishPreviewRequest) async -> Bool {
        guard !isWorking else { return false }
        cancelAutomaticPublishSchedule()
        do {
            let payload = try await webPublishPreview(request, retainsForNativeUI: true)
            let issues = payload.previews.flatMap(\.issues)
            if !issues.isEmpty {
                pendingSelectedPublishLintReview = SelectedPublishLintReview(reviewToken: payload.token,
                    moduleIDs: payload.moduleIDs, issues: issues)
                return false
            }
            return try await confirmWebPublish(token: payload.token).ok
        } catch {
            presentPublishReviewError(error)
            return false
        }
    }

    func confirmSelectedPublishReview(_ review: SelectedPublishLintReview) async {
        guard !isWorking else { return }
        pendingSelectedPublishLintReview = nil
        do { _ = try await confirmWebPublish(token: review.reviewToken) }
        catch { presentPublishReviewError(error) }
    }

    func retainNativePublishPreview(_ payload: WebPublishPreviewPayload) {
        guard var preview = payload.previews.first else { return }
        preview.reviewToken = payload.token
        pendingPublishPreview = preview
        selectedModuleID = Self.combinedModuleSelectionID
        statusMessage = GitHubPublishPlanner.previewStatus(preview)
    }

    private func presentPublishReviewError(_ error: any Error) {
        if isCurrentWorkCancellation(error) { return }
        if error as? PreviewContentSaveError == .changed {
            presentedError = "预览已过期，或内容、发布目标、工作区已变化。请重新预览后确认。"
        } else { presentedError = error.localizedDescription }
    }

    func selectedPublishTarget(_ destination: PublishDestination) -> String {
        switch destination {
        case .local: settings.localModuleDirectory
        case .gitHub: PublishCoordinator.repositoryKey(settings.github)
        }
    }

    func runSelectedPublish(
        _ attempt: SelectedPublishAttempt, destinations: Set<PublishDestination>, reviewed: WebPublishTicket? = nil
    ) async -> Bool {
        cancelAutomaticPublishSchedule()
        beginWork(.publishing)
        workActivity.title = "所选模块发布"
        defer { endWork(.publishing) }
        selectedPublishAttempt = attempt
        do {
            enqueueConfiguration(attempt, fileName: "selected-publish.json")
            try await flushPersistence()
        } catch {
            presentedError = "无法保存发布恢复记录：\(error.localizedDescription)"
            return false
        }
        var metrics: [PublishDestination: StageMetricsRecorder] = [:]
        var started: [PublishDestination: ContinuousClock.Instant] = [:]
        let result = await PublishCoordinator.executeSelected(
            attempt: attempt, destinations: destinations,
            isCancelled: { self.workCancellationRequested },
            publish: { destination in
                let recorder = StageMetricsRecorder()
                metrics[destination] = recorder
                started[destination] = .now
                self.setWorkStage(.publish, moduleID: Self.combinedModuleSelectionID, moduleName: destination.title + " 所选模块发布")
                return try await StageMetricsContext.$current.withValue(recorder) {
                guard attempt.moduleIDs.isSubset(of: Set(self.modules.map(\.id))) else {
                    throw RelayError.invalidOutput("部分模块已移除，请重新选择发布模块。")
                }
                guard attempt.results.first(where: { $0.destination == destination })?.target
                        == self.selectedPublishTarget(destination) else {
                    throw RelayError.invalidOutput("发布目录或仓库已变更，请重新选择模块发布。")
                }
                switch destination {
                case .local:
                    guard self.settings.publishToLocal, !self.settings.localModuleDirectory.isEmpty else {
                        throw RelayError.invalidOutput("本地发布未开启或目录未配置。")
                    }
                    let files: [PublishFile]
                    if let prepared = reviewed?.files[.local] { files = prepared }
                    else { files = try await self.selectedLocalPublishedFiles(moduleIDs: attempt.moduleIDs) }
                    guard !files.isEmpty else { throw RelayError.noFilesToPublish }
                    try self.enterNonCancellableWorkPhase(statusMessage: "正在写入所选本地模块…")
                    try await self.publishSelectedLocalFiles(files, expectedExistingHashes: reviewed?.localHashes ?? [:])
                    self.workActivity.canCancel = true
                    return PublishReport(publishedFiles: files.map(\.name))
                case .gitHub:
                    guard self.settings.publishToGitHub, self.settings.github.isConfigured else {
                        throw RelayError.invalidOutput("GitHub 发布未开启或仓库未配置。")
                    }
                    let report = try await self.publishSelectedModulesInternal(moduleIDs: attempt.moduleIDs, reviewed: reviewed)
                    self.workActivity.canCancel = true
                    return report
                }
                }
            },
            didComplete: { latest, target in
                self.setWorkStage(nil, moduleID: Self.combinedModuleSelectionID, moduleName: target.destination.title)
                self.workActivity.canCancel = true
                self.selectedPublishAttempt = latest
                self.statusMessage = latest.summary
                do {
                    self.enqueueConfiguration(latest, fileName: "selected-publish.json")
                    try await self.flushPersistence()
                } catch {
                    self.presentedError = "发布结果未能保存到恢复记录：\(error.localizedDescription)"
                }
                self.recordHistory([UpdateHistoryEntry(
                    moduleName: "\(target.destination.title) 所选模块发布",
                    outcome: target.status == .succeeded ? .published : (target.status == .skipped ? .unchanged : .failed),
                    duration: started[target.destination].map { StageMetricsRecorder.elapsed(since: $0) } ?? 0,
                    message: target.message, publishedFiles: target.publishedFiles,
                    commitSHA: target.commitSHA, publishDestination: target.destination,
                    stageMetrics: metrics[target.destination]?.snapshot
                )])
            }
        )
        if result.results.filter({ $0.status == .succeeded }).count == 2 {
            await recordModuleSyncBaselines(moduleIDs: attempt.moduleIDs)
        }
        statusMessage = result.summary
        return result.succeeded
    }

    func previewPublish() async {
        guard !isWorking else { return }
        cancelAutomaticPublishSchedule()
        do { retainNativePublishPreview(try await webPublishPreview(WebPublishPreviewRequest(scope: "githubAll"), retainsForNativeUI: true)) }
        catch { presentPublishReviewError(error) }
    }

    func confirmPendingPublish() async {
        guard let preview = pendingPublishPreview, !isWorking else { return }
        if preview.destination == .gitHub {
            guard let token = preview.reviewToken else {
                pendingPublishPreview = nil
                presentedError = "请重新生成发布预览后确认。"
                return
            }
            pendingPublishPreview = nil
            do { _ = try await confirmWebPublish(token: token) }
            catch { presentPublishReviewError(error) }
            return
        }
        beginWork(.confirmingPublish)
        defer { endWork(.confirmingPublish) }
        do {
            let currentRoot = URL(filePath: settings.localModuleDirectory).standardizedFileURL.path
            guard settings.publishToLocal,
                  currentRoot == URL(filePath: preview.targetDescription).standardizedFileURL.path,
                  let expected = preview.localExpectedHashes,
                  preview.localReviewFingerprint == localCleanupReviewFingerprint(),
                  Set(expected.keys) == Set(preview.deletedFiles) else { throw PreviewContentSaveError.changed }
            for (path, hash) in expected {
                let data = try await fileStore.readPublishedFile(relativePath: path, rootDirectoryPath: currentRoot)
                guard (data?.sha256String ?? "<missing>") == hash else { throw PreviewContentSaveError.changed }
            }
            let plan = LocalPublishedFilesPlanner.confirmedCleanupPlan(preview: preview,
                previousRootDirectory: settings.localPublishedRootDirectory,
                previousPublishedPaths: settings.localPublishedFilePaths)
            try enterNonCancellableWorkPhase(statusMessage: "正在清理确认过的本地旧文件…")
            _ = try await fileStore.exportPublishedFiles([], toRootDirectory: plan.targetDirectory,
                removingObsoleteRelativePaths: plan.obsoleteRelativePaths,
                knownManagedRelativePaths: plan.knownManagedRelativePaths, expectedExistingHashes: expected)
            settings.localPublishedRootDirectory = plan.persistedRootDirectory
            settings.localPublishedFilePaths = plan.persistedFilePaths
            pendingPublishPreview = nil
            saveSettings()
            try await flushPersistence()
            statusMessage = plan.statusMessage
        } catch {
            pendingPublishPreview = nil
            presentPublishReviewError(error)
        }
    }

    func dismissPendingPublishPreview() {
        pendingPublishPreview = nil
        statusMessage = "已取消发布预览"
    }
}
