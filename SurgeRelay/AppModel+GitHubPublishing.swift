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
            combinedModuleEnabled: settings.combinedModuleEnabled
        )
    }

    private func githubPublishTokenAndRefreshRepositoryPrivacy() async throws -> String {
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
        return GitHubPublishPlanner.preview(
            settings: settings.github,
            pathPlan: preparation.pathPlan,
            report: report
        )
    }

    func publishAllInternal(allowDeleting: Bool = true) async throws -> PublishReport {
        let preparation = try await prepareGitHubPublish()
        let stalePaths = allowDeleting ? preparation.pathPlan.stalePaths : []
        try enterNonCancellableWorkPhase(
            statusMessage: "正在提交 GitHub 发布，已进入不可取消阶段…"
        )
        let report = try await githubClient.publish(
            files: preparation.files,
            deleting: stalePaths,
            settings: settings.github,
            token: preparation.token
        )
        if GitHubPublishPlanner.shouldPersistPathPlan(preparation.pathPlan, allowDeleting: allowDeleting) {
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
        return GitHubPublishPreparation(
            token: token,
            files: preparedFiles.files,
            pathPlan: preparedFiles.pathPlan
        )
    }

    func publishSelectedModulesInternal(moduleIDs: Set<UUID>) async throws -> PublishReport {
        try checkCurrentWorkCancellation()
        try Task.checkCancellation()
        let plan = PublishCoordinator.selectedPlan(modules: modules, moduleIDs: moduleIDs)
        try GitHubPublishPlanner.validatePublishableSelection(plan)
        let token = try await githubPublishTokenAndRefreshRepositoryPrivacy()
        let files = try await selectedPublishedFiles(plan: plan)
        guard !files.isEmpty else { throw RelayError.noFilesToPublish }
        let currentPaths = files.map(\.name)
        try enterNonCancellableWorkPhase(
            statusMessage: "正在提交所选模块，已进入不可取消阶段…"
        )
        let report = try await githubClient.publish(
            files: files,
            deleting: [],
            settings: settings.github,
            token: token
        )
        let pathUpdate = GitHubPublishPlanner.selectedPublishPathUpdate(
            currentPaths: currentPaths,
            settings: settings.github,
            knownRepositoryKey: settings.githubPublishedRepositoryKey,
            knownPublishedPaths: settings.githubPublishedFilePaths
        )
        settings.githubPublishedRepositoryKey = pathUpdate.repositoryKey
        settings.githubPublishedFilePaths = pathUpdate.publishedPaths
        saveSettings()
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
