import Foundation

@MainActor
extension AppModel {
    func publishAll() async {
        guard !isWorking else { return }
        guard settings.publishToGitHub else {
            statusMessage = "GitHub 发布未开启，请在设置中开启后重试"
            return
        }
        guard settings.github.isConfigured else {
            statusMessage = "请先完成 GitHub 发布配置"
            return
        }
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
        guard !moduleIDs.isEmpty else {
            statusMessage = "请选择要发布的模块"
            return false
        }
        let selected = modules.filter { moduleIDs.contains($0.id) }
        let hasLocalSelection = selected.contains { $0.hasLocalStorageTarget }
        let hasGitHubSelection = selected.contains { $0.hasGitHubStorageTarget }
        let publishLocally = settings.publishToLocal &&
            hasLocalSelection &&
            !settings.localModuleDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let publishToGitHub = settings.publishToGitHub &&
            settings.github.isConfigured && hasGitHubSelection
        guard publishLocally || publishToGitHub else {
            statusMessage = "所选模块没有可发布到本地或 GitHub 的独立模块"
            return false
        }
        cancelAutomaticPublishSchedule()
        beginWork(.publishing)
        defer { endWork(.publishing) }
        do {
            var changedFileCount = 0
            var publishedDestinations: [String] = []

            if publishLocally {
                do {
                    let files = try await selectedLocalPublishedFiles(moduleIDs: moduleIDs)
                    if !files.isEmpty {
                        try await publishSelectedLocalFiles(files)
                        changedFileCount += files.count
                        publishedDestinations.append("本地")
                    }
                } catch {
                    if isCurrentWorkCancellation(error) { return false }
                    if GitHubPublishPlanner.isNoFilesToPublish(error) {
                        // 所选本地模块没有可发布的独立输出，跳过本地发布
                    } else { throw error }
                }
            }

            guard shouldContinueCurrentWork() else { return false }

            if publishToGitHub {
                do {
                    let report = try await publishSelectedModulesInternal(moduleIDs: moduleIDs)
                    changedFileCount += report.changedFileCount
                    recordGitHubPublish(report)
                    publishedDestinations.append("GitHub")
                } catch {
                    if isCurrentWorkCancellation(error) { return false }
                    if GitHubPublishPlanner.isNoFilesToPublish(error) {
                        // 所选 GitHub 模块没有可发布的独立输出，跳过 GitHub 发布
                    } else { throw error }
                }
            }

            guard shouldContinueCurrentWork() else { return false }
            guard changedFileCount > 0 else {
                statusMessage = "所选模块没有可发布的独立输出"
                return false
            }
            statusMessage = "已将所选模块发布到\(publishedDestinations.joined(separator: " 和 "))（\(changedFileCount) 个文件变更）"
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
}
