import Foundation

private struct GitHubPublishPreparation {
    var token: String
    var files: [PublishFile]
    var pathPlan: GitHubPublishedPathPlan
}

@MainActor
extension AppModel {
    func publishAll() async {
        guard !isWorking else { return }
        cancelAutomaticPublishSchedule()
        beginWork(.publishing)
        defer { endWork(.publishing) }
        do {
            let preview = try await githubPublishPreview()
            guard shouldContinueCurrentWork() else { return }
            if preview.requiresDeletionConfirmation {
                pendingPublishPreview = preview
                statusMessage = GitHubPublishPlanner.deletionConfirmationStatus(
                    deletedFileCount: preview.deletedFiles.count
                )
                return
            }
            let report = try await publishAllInternal()
            guard shouldContinueCurrentWork() else { return }
            statusMessage = GitHubPublishPlanner.reportStatus(
                for: .publishAll,
                report: report,
                scopeTitle: githubPublishPlan.scopeTitle
            )
            recordGitHubPublish(report)
        } catch {
            if isCurrentWorkCancellation(error) { return }
            if GitHubPublishPlanner.isNoFilesToPublish(error) {
                statusMessage = GitHubPublishPlanner.noFilesStatus(for: .publishAll)
                return
            }
            presentedError = error.localizedDescription
        }
    }

    func publishModules(moduleIDs: Set<UUID>) async -> Bool {
        guard !isWorking else { return false }
        guard settings.publishToGitHub else {
            statusMessage = "GitHub 发布未开启"
            return false
        }
        guard !moduleIDs.isEmpty else {
            statusMessage = "请选择要发布的模块"
            return false
        }
        cancelAutomaticPublishSchedule()
        beginWork(.publishing)
        defer { endWork(.publishing) }
        do {
            let report = try await publishSelectedModulesInternal(moduleIDs: moduleIDs)
            guard shouldContinueCurrentWork() else { return false }
            statusMessage = GitHubPublishPlanner.reportStatus(
                for: .publishSelected,
                report: report,
                scopeTitle: githubPublishPlan.scopeTitle
            )
            recordGitHubPublish(report)
            return true
        } catch {
            if isCurrentWorkCancellation(error) { return false }
            if GitHubPublishPlanner.isNoFilesToPublish(error) {
                statusMessage = GitHubPublishPlanner.noFilesStatus(for: .publishSelected)
                return false
            }
            presentedError = error.localizedDescription
            return false
        }
    }

    func previewPublish() async {
        guard !isWorking else { return }
        guard settings.publishToGitHub else {
            statusMessage = "GitHub 发布未开启；本地发布会在合并时自动生成清理预览"
            return
        }
        cancelAutomaticPublishSchedule()
        beginWork(.previewingPublish)
        defer { endWork(.previewingPublish) }
        do {
            let preview = try await githubPublishPreview()
            guard shouldContinueCurrentWork() else { return }
            pendingPublishPreview = preview
            statusMessage = GitHubPublishPlanner.previewStatus(preview)
        } catch {
            if isCurrentWorkCancellation(error) { return }
            if GitHubPublishPlanner.isNoFilesToPublish(error) {
                statusMessage = GitHubPublishPlanner.noFilesStatus(for: .preview)
                return
            }
            presentedError = error.localizedDescription
        }
    }

    func confirmPendingPublish() async {
        guard let preview = pendingPublishPreview, !isWorking else { return }
        beginWork(.confirmingPublish)
        defer { endWork(.confirmingPublish) }
        do {
            switch preview.destination {
            case .gitHub:
                let report = try await publishAllInternal(allowDeleting: true)
                guard shouldContinueCurrentWork() else { return }
                pendingPublishPreview = nil
                statusMessage = GitHubPublishPlanner.reportStatus(
                    for: .publishAll,
                    report: report,
                    scopeTitle: githubPublishPlan.scopeTitle
                )
                recordGitHubPublish(report)
            case .local:
                try enterNonCancellableWorkPhase(
                    statusMessage: "正在清理本地旧文件，已进入不可取消阶段…"
                )
                let plan = LocalPublishedFilesPlanner.confirmedCleanupPlan(
                    preview: preview,
                    previousRootDirectory: settings.localPublishedRootDirectory,
                    previousPublishedPaths: settings.localPublishedFilePaths
                )
                _ = try await fileStore.exportPublishedFiles(
                    [],
                    toRootDirectory: plan.targetDirectory,
                    removingObsoleteRelativePaths: plan.obsoleteRelativePaths,
                    knownManagedRelativePaths: plan.knownManagedRelativePaths
                )
                settings.localPublishedRootDirectory = plan.persistedRootDirectory
                settings.localPublishedFilePaths = plan.persistedFilePaths
                pendingPublishPreview = nil
                saveSettings()
                statusMessage = plan.statusMessage
            }
        } catch {
            if isCurrentWorkCancellation(error) { return }
            if GitHubPublishPlanner.isNoFilesToPublish(error) {
                pendingPublishPreview = nil
                statusMessage = GitHubPublishPlanner.noFilesStatus(for: .publishAll)
                return
            }
            presentedError = error.localizedDescription
        }
    }

    func dismissPendingPublishPreview() {
        pendingPublishPreview = nil
        statusMessage = "已取消发布预览"
    }

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

    private func publishSelectedModulesInternal(moduleIDs: Set<UUID>) async throws -> PublishReport {
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
