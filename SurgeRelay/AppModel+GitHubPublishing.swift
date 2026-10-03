import Foundation

private struct GitHubPublishPreparation {
    var token: String
    var files: [PublishFile]
    var pathPlan: GitHubPublishedPathPlan
}

@MainActor
extension AppModel {
    var githubPublishPlan: PublishPlan {
        PublishCoordinator.plan(
            modules: modules,
            combinedModuleEnabled: settings.combinedModuleEnabled,
            destination: .gitHub
        )
    }

    func githubPublishTokenAndRefreshRepositoryPrivacy() async throws -> String {
        let token = ensureGitHubTokenLoaded(showStatusMessage: false)
        guard !token.isEmpty else { throw RelayError.githubTokenMissing }
        let isPrivate = try await githubClient.test(settings: settings.github, token: token)
        try checkCurrentWorkCancellation()
        try Task.checkCancellation()
        let privacyUpdate = GitHubPublishPlanner.repositoryPrivacyUpdate(
            currentValue: settings.github.repositoryIsPrivate,
            detectedValue: isPrivate
        )
        if privacyUpdate.shouldPersist {
            settings.github.repositoryIsPrivate = privacyUpdate.repositoryIsPrivate
            saveSettings()
        }
        return token
    }

    func githubPublishPreview() async throws -> PublishPreview {
        let preparation = try await prepareGitHubPublish()
        let report = try await githubClient.previewPublish(
            files: preparation.files,
            deleting: preparation.pathPlan.stalePaths,
            settings: settings.github,
            token: preparation.token
        )
        var preview = GitHubPublishPlanner.preview(settings: settings.github, pathPlan: preparation.pathPlan, report: report)
        preview.issues = await Task.detached { ModuleLintPlanner.check(files: preparation.files) }.value
        return preview
    }

    func publishAllInternal(allowDeleting: Bool = true, reviewed: WebPublishTicket? = nil) async throws -> PublishReport {
        let preparation: GitHubPublishPreparation
        if let reviewed, let files = reviewed.files[.gitHub], let pathPlan = reviewed.pathPlan {
            preparation = GitHubPublishPreparation(token: try await githubPublishTokenAndRefreshRepositoryPrivacy(), files: files, pathPlan: pathPlan)
        } else {
            preparation = try await prepareGitHubPublish()
        }
        let publishingSettings = reviewed?.settings.github ?? settings.github
        if let reviewed, settings.github != reviewed.settings.github {
            throw PreviewContentSaveError.changed
        }
        let stalePaths = allowDeleting ? preparation.pathPlan.stalePaths : []
        try enterNonCancellableWorkPhase(
            statusMessage: "正在提交 GitHub 发布，已进入不可取消阶段…"
        )
        let recorder = StageMetricsContext.current ?? StageMetricsRecorder()
        let started = ContinuousClock.now
        var report = try await recorder.measure(.publish, reason: "GitHub", bytes: { report in
            (nil, Int64(preparation.files.filter { report.publishedFiles.contains($0.name) }.reduce(0) { $0 + $1.data.count }))
        }) {
            try await githubClient.publish(
            files: preparation.files,
            deleting: stalePaths,
            settings: publishingSettings,
            token: preparation.token,
            expectedHeadCommitSHA: reviewed?.gitHubHead
        )
        }
        report.duration = StageMetricsRecorder.elapsed(since: started)
        report.stageMetrics = recorder.snapshot
        if PublishCoordinator.repositoryKey(settings.github) == PublishCoordinator.repositoryKey(publishingSettings),
           GitHubPublishPlanner.shouldPersistPathPlan(preparation.pathPlan, allowDeleting: allowDeleting) {
            settings.githubPublishedRepositoryKey = preparation.pathPlan.repositoryKey
            settings.githubPublishedFilePaths = preparation.pathPlan.currentPaths
            saveSettings()
        }
        return report
    }

    private func prepareGitHubPublish() async throws -> GitHubPublishPreparation {
        try checkCurrentWorkCancellation()
        try Task.checkCancellation()
        let plan = githubPublishPlan
        try GitHubPublishPlanner.validatePublishableSelection(plan)
        let token = try await githubPublishTokenAndRefreshRepositoryPrivacy()
        let data = settings.combinedModuleEnabled ? try await fileStore.readCombined() : nil
        try checkCurrentWorkCancellation()
        let files = try await publishedFiles(
            plan: plan,
            combinedData: data,
            includeAssets: true,
            destination: .gitHub
        )
        try checkCurrentWorkCancellation()
        let preparedFiles = try GitHubPublishPlanner.preparedFiles(
            plan: plan,
            files: files,
            settings: settings.github,
            knownRepositoryKey: settings.githubPublishedRepositoryKey,
            knownPublishedPaths: settings.githubPublishedFilePaths
        )
        let issues = await Task.detached { ModuleLintPlanner.check(files: files, ownedModuleIDs: plan.assetModuleIDs) }.value
        try ModuleLintPlanner.throwIfBlocking(issues)
        return GitHubPublishPreparation(
            token: token,
            files: preparedFiles.files,
            pathPlan: preparedFiles.pathPlan
        )
    }

    func publishSelectedModulesInternal(moduleIDs: Set<UUID>, reviewed: WebPublishTicket? = nil) async throws -> PublishReport {
        try checkCurrentWorkCancellation()
        try Task.checkCancellation()
        let plan = PublishCoordinator.selectedPlan(
            modules: modules,
            moduleIDs: moduleIDs,
            combinedModuleEnabled: settings.combinedModuleEnabled,
            destination: .gitHub
        )
        try GitHubPublishPlanner.validatePublishableSelection(plan)
        let token = try await githubPublishTokenAndRefreshRepositoryPrivacy()
        let publishingSettings = reviewed?.settings.github ?? settings.github
        if let reviewed, settings.github != reviewed.settings.github {
            throw PreviewContentSaveError.changed
        }
        let files: [PublishFile]
        if let prepared = reviewed?.files[.gitHub] { files = prepared }
        else { files = try await selectedPublishedFiles(plan: plan) }
        guard !files.isEmpty else { throw RelayError.noFilesToPublish }
        let issues = await Task.detached { ModuleLintPlanner.check(files: files, ownedModuleIDs: plan.assetModuleIDs) }.value
        try ModuleLintPlanner.throwIfBlocking(issues)
        let currentPaths = files.map(\.name)
        try enterNonCancellableWorkPhase(
            statusMessage: "正在提交所选模块，已进入不可取消阶段…"
        )
        let recorder = StageMetricsContext.current ?? StageMetricsRecorder()
        let started = ContinuousClock.now
        var report = try await recorder.measure(.publish, reason: "GitHub", bytes: { report in
            (nil, Int64(files.filter { report.publishedFiles.contains($0.name) }.reduce(0) { $0 + $1.data.count }))
        }) {
            try await githubClient.publish(
            files: files,
            deleting: [],
            settings: publishingSettings,
            token: token,
            expectedHeadCommitSHA: reviewed?.gitHubHead
        )
        }
        report.duration = StageMetricsRecorder.elapsed(since: started)
        report.stageMetrics = recorder.snapshot
        let pathUpdate = GitHubPublishPlanner.selectedPublishPathUpdate(
            currentPaths: currentPaths,
            settings: publishingSettings,
            knownRepositoryKey: settings.githubPublishedRepositoryKey,
            knownPublishedPaths: settings.githubPublishedFilePaths
        )
        if PublishCoordinator.repositoryKey(settings.github) == PublishCoordinator.repositoryKey(publishingSettings) {
            settings.githubPublishedRepositoryKey = pathUpdate.repositoryKey
            settings.githubPublishedFilePaths = pathUpdate.publishedPaths
            saveSettings()
        }
        return report
    }

    private func selectedPublishedFiles(plan: PublishPlan) async throws -> [PublishFile] {
        try await publishedFiles(
            plan: plan,
            combinedData: nil,
            includeAssets: true,
            destination: .gitHub
        )
    }

    func recordGitHubPublish(_ report: PublishReport) {
        guard let entry = GitHubPublishPlanner.historyEntry(for: report) else { return }
        recordHistory([entry])
    }
}
