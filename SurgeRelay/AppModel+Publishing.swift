import Foundation

private struct GitHubPublishPreparation {
    var token: String
    var files: [PublishFile]
    var pathPlan: GitHubPublishedPathPlan
}

@MainActor
extension AppModel {
    func scheduleAutomaticPublish() {
        let admission = AutomaticPublishPlanner.scheduleAdmission(
            context: automaticPublishContext(),
            plan: githubPublishPlan
        )
        guard admission.isAccepted else {
            applyAutomaticPublishAdmission(admission)
            return
        }
        automaticPublishTask?.cancel()
        let scheduledAt = Date.now
        automaticPublishScheduledAt = scheduledAt
        automaticPublishRunsAt = scheduledAt.addingTimeInterval(TimeInterval(Self.automaticPublishDelaySeconds))
        automaticPublishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.automaticPublishDelaySeconds))
            guard !Task.isCancelled, let self else { return }
            while self.isWorking, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            let runAdmission = AutomaticPublishPlanner.runAdmission(
                context: self.automaticPublishContext(),
                plan: self.githubPublishPlan,
                hasCachedStandaloneOutput: await self.hasGitHubAutomaticPublishableFiles()
            )
            guard runAdmission.isAccepted else {
                self.applyAutomaticPublishAdmission(runAdmission)
                return
            }
            self.clearAutomaticPublishSchedule()
            self.beginWork(.automaticPublishing)
            defer {
                self.endWork(.automaticPublishing)
                self.automaticPublishTask = nil
            }
            do {
                guard self.shouldContinueCurrentWork() else { return }
                let preview = try await self.githubPublishPreview()
                guard self.shouldContinueCurrentWork() else { return }
                if preview.requiresDeletionConfirmation {
                    self.pendingPublishPreview = preview
                    self.statusMessage = GitHubPublishPlanner.automaticDeletionConfirmationStatus(
                        deletedFileCount: preview.deletedFiles.count
                    )
                    return
                }
                let report = try await self.publishAllInternal()
                guard self.shouldContinueCurrentWork() else { return }
                self.statusMessage = GitHubPublishPlanner.automaticReportStatus(report)
                self.recordGitHubPublish(report)
            } catch {
                guard !self.isCurrentWorkCancellation(error) else { return }
                if GitHubPublishPlanner.isNoFilesToPublish(error) {
                    self.statusMessage = AutomaticPublishPlanner.noStandaloneFilesStatus
                    return
                }
                self.presentedError = "GitHub 自动发布失败：\(error.localizedDescription)"
            }
        }
    }

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
                _ = try await fileStore.exportPublishedFiles(
                    [],
                    toRootDirectory: preview.targetDescription,
                    removingObsoleteRelativePaths: preview.deletedFiles,
                    knownManagedRelativePaths: LocalPublishedFilesPlanner.knownManagedPathsForConfirmedCleanup(
                        preview: preview,
                        previousRootDirectory: settings.localPublishedRootDirectory,
                        previousPublishedPaths: settings.localPublishedFilePaths
                    )
                )
                settings.localPublishedRootDirectory = preview.targetDescription
                settings.localPublishedFilePaths = preview.activeFiles
                pendingPublishPreview = nil
                saveSettings()
                statusMessage = "已清理 \(preview.deletedFiles.count) 个本地旧文件"
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

    func rebuildCombinedFromCache() async {
        let rebuildGeneration = localChangeGeneration
        let enabled = ModuleRefreshPlanner.combinedContributorModules(
            in: modules,
            combinedModuleEnabled: settings.combinedModuleEnabled
        )
        guard !enabled.isEmpty else {
            try? await fileStore.removeCombined()
            try? await publishCurrentFiles(combinedData: nil, includeAssets: false)
            scheduleAutomaticPublish()
            return
        }
        var components: [(RelayModule, String)] = []
        for module in enabled {
            guard let content = try? await fileStore.readComponent(id: module.id) else { return }
            let materialized = await processingWorker.materialize(
                content,
                overrides: module.argumentOverrides
            )
            components.append((module, materialized))
        }
        do {
            try await writeCombinedModule(components)
            guard rebuildGeneration == localChangeGeneration else {
                await rebuildCombinedFromCache()
                return
            }
            scheduleAutomaticPublish()
        } catch {
            presentedError = "自动合并失败：\(error.localizedDescription)"
        }
    }

    func writeCombinedModule(_ components: [(RelayModule, String)]) async throws {
        let merged = try await processingWorker.merge(
            components,
            engineRevision: upstreamState.revision
        )
        try await fileStore.writeCombined(merged)
        try await publishCurrentFiles(combinedData: Data(merged.utf8), includeAssets: false)
    }

    func publishCurrentFiles(combinedData: Data?, includeAssets: Bool) async throws {
        if settings.publishToLocal {
            let files = try await currentPublishedFiles(
                combinedData: combinedData,
                includeAssets: includeAssets,
                destination: .local
            )
            let localPublishPlan = LocalPublishedFilesPlanner.plan(
                files: files,
                targetDirectory: settings.localModuleDirectory,
                previousRootDirectory: settings.localPublishedRootDirectory,
                previousPublishedPaths: settings.localPublishedFilePaths
            )
            _ = try await fileStore.exportPublishedFiles(
                files,
                toRootDirectory: localPublishPlan.targetDirectory,
                removingObsoleteRelativePaths: [],
                knownManagedRelativePaths: localPublishPlan.knownManagedPaths
            )
            switch LocalPublishedFilesPlanner.completion(afterExporting: localPublishPlan) {
            case .persisted(let rootDirectory, let filePaths):
                settings.localPublishedRootDirectory = rootDirectory
                settings.localPublishedFilePaths = filePaths
                if pendingPublishPreview?.destination == .local {
                    pendingPublishPreview = nil
                }
                saveSettings()
            case .requiresCleanup(let preview, let message):
                pendingPublishPreview = preview
                statusMessage = message
            }
        }
    }

    func cleanupLegacyOutputFiles() async {
        let paths = legacyPublishedRelativePaths()
        for directory in legacyOutputCleanupDirectories() {
            _ = try? await fileStore.removeLegacyPublishedFiles(in: directory, relativePaths: paths)
        }
    }

    func cancelAutomaticPublishSchedule() {
        if workActivity.kind == .automaticPublishing, !workActivity.canCancel {
            clearAutomaticPublishSchedule()
            return
        }
        automaticPublishTask?.cancel()
        automaticPublishTask = nil
        clearAutomaticPublishSchedule()
    }

    func clearAutomaticPublishSchedule() {
        automaticPublishScheduledAt = nil
        automaticPublishRunsAt = nil
    }

    var githubPublishPlan: PublishPlan {
        PublishCoordinator.plan(
            modules: modules,
            combinedModuleEnabled: settings.combinedModuleEnabled
        )
    }

    func automaticPublishContext() -> AutomaticPublishContext {
        AutomaticPublishPlanner.context(
            settings: settings,
            tokenIsAvailable: !ensureGitHubTokenLoaded(showStatusMessage: false).isEmpty
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

    private func githubPublishPreview() async throws -> PublishPreview {
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

    private func publishAllInternal(allowDeleting: Bool = true) async throws -> PublishReport {
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
        guard hasGitHubPublishableModuleSelection else { throw RelayError.noFilesToPublish }
        let token = try await githubPublishTokenAndRefreshRepositoryPrivacy()
        let data = settings.combinedModuleEnabled ? try await fileStore.readCombined() : nil
        try checkCurrentWorkCancellation()
        let files = try await currentPublishedFiles(combinedData: data, includeAssets: true, destination: .gitHub)
        try checkCurrentWorkCancellation()
        guard !files.isEmpty else { throw RelayError.noFilesToPublish }
        let pathPlan = GitHubPublishPlanner.pathPlan(
            currentPaths: files.map(\.name),
            settings: settings.github,
            knownRepositoryKey: settings.githubPublishedRepositoryKey,
            knownPublishedPaths: settings.githubPublishedFilePaths
        )
        return GitHubPublishPreparation(
            token: token,
            files: files,
            pathPlan: pathPlan
        )
    }

    private func publishSelectedModulesInternal(moduleIDs: Set<UUID>) async throws -> PublishReport {
        try checkCurrentWorkCancellation()
        try Task.checkCancellation()
        let plan = PublishCoordinator.selectedPlan(modules: modules, moduleIDs: moduleIDs)
        guard plan.hasPublishableModuleSelection else { throw RelayError.noFilesToPublish }
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

    private func currentPublishedFiles(
        combinedData: Data?,
        includeAssets: Bool,
        destination: PublishDestination
    ) async throws -> [PublishFile] {
        try await publishedFiles(
            plan: githubPublishPlan,
            combinedData: combinedData,
            includeAssets: includeAssets,
            destination: destination
        )
    }

    private func selectedPublishedFiles(plan: PublishPlan) async throws -> [PublishFile] {
        try await publishedFiles(
            plan: plan,
            combinedData: nil,
            includeAssets: true,
            destination: .gitHub
        )
    }

    private func publishedFiles(
        plan: PublishPlan,
        combinedData: Data?,
        includeAssets: Bool,
        destination: PublishDestination
    ) async throws -> [PublishFile] {
        try await PublishFileAssembler.files(
            request: PublishFileAssemblyRequest(
                plan: plan,
                combinedData: combinedData,
                combinedFileName: settings.combinedModuleFileName,
                includeAssets: includeAssets,
                destination: destination,
                localModuleDirectory: settings.localModuleDirectory
            ),
            readComponent: { [fileStore] id in
                try? await fileStore.readComponent(id: id)
            },
            generatedAssetFiles: { [fileStore] ids in
                try await fileStore.generatedAssetFiles(for: ids)
            },
            materialize: { [processingWorker] content, overrides in
                await processingWorker.materialize(content, overrides: overrides)
            },
            applyingModuleMetadata: { [processingWorker] name, category, content in
                await processingWorker.applyingModuleMetadata(
                    name: name,
                    category: category,
                    to: content
                )
            },
            cancellationCheckpoint: {
                try checkCurrentWorkCancellation()
                try Task.checkCancellation()
            }
        )
    }

    private func legacyOutputCleanupDirectories() -> [String] {
        LegacyOutputCleanupPlanner.cleanupDirectories(
            outputDirectory: settings.outputDirectory,
            configurationDirectory: configurationDirectoryPath,
            localModuleDirectory: settings.localModuleDirectory
        )
    }

    private func legacyPublishedRelativePaths() -> [String] {
        LegacyOutputCleanupPlanner.publishedRelativePaths(
            combinedModuleFileName: settings.combinedModuleFileName,
            managedEngineFileName: settings.managedEngineFileName
        )
    }

    private var hasGitHubPublishableModuleSelection: Bool {
        githubPublishPlan.hasPublishableModuleSelection
    }

    private func applyAutomaticPublishAdmission(_ admission: AutomaticPublishAdmission) {
        if admission.shouldClearSchedule {
            clearAutomaticPublishSchedule()
        }
        if let statusMessage = admission.statusMessage {
            self.statusMessage = statusMessage
        }
    }

    private func hasGitHubAutomaticPublishableFiles() async -> Bool {
        await AutomaticPublishPlanner.hasCachedStandaloneOutput(
            plan: githubPublishPlan
        ) { [fileStore] id in
            await fileStore.hasComponent(id: id)
        }
    }

    private func recordGitHubPublish(_ report: PublishReport) {
        guard let entry = GitHubPublishPlanner.historyEntry(for: report) else { return }
        recordHistory([entry])
    }
}
