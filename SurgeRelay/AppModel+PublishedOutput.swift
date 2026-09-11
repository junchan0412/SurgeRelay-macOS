import Foundation

@MainActor
extension AppModel {
    @discardableResult
    func rebuildCombinedFromCache(schedulesAutomaticPublish: Bool = true) async -> Bool {
        let rebuildGeneration = localChangeGeneration
        let enabled = ModuleRefreshPlanner.combinedContributorModules(
            in: modules,
            combinedModuleEnabled: settings.combinedModuleEnabled
        )
        do {
            try checkCurrentWorkCancellation()
            var components: [(RelayModule, String)] = []
            for module in enabled {
                try checkCurrentWorkCancellation()
                guard let content = try? await fileStore.readComponent(id: module.id) else {
                    statusMessage = "缺少模块缓存，输出尚未刷新"
                    presentedError = "“\(module.name)”缺少转换缓存，请先更新该模块。当前总模块已保留。"
                    return false
                }
                let materialized = await processingWorker.materialize(content, overrides: module.argumentOverrides)
                components.append((module, materialized))
            }
            try checkCurrentWorkCancellation()
            guard rebuildGeneration == localChangeGeneration else {
                return await rebuildCombinedFromCache(schedulesAutomaticPublish: schedulesAutomaticPublish)
            }
            if enabled.isEmpty {
                try await fileStore.removeCombined()
                try await publishCurrentFiles(combinedData: nil, includeAssets: false)
            } else if !(try await writeCombinedModule(components, generation: rebuildGeneration)) {
                guard !workCancellationRequested, !Task.isCancelled else { return false }
                return await rebuildCombinedFromCache(schedulesAutomaticPublish: schedulesAutomaticPublish)
            }
            try checkCurrentWorkCancellation()
            guard rebuildGeneration == localChangeGeneration else {
                return await rebuildCombinedFromCache(schedulesAutomaticPublish: schedulesAutomaticPublish)
            }
            if schedulesAutomaticPublish { scheduleAutomaticPublish() }
            return true
        } catch {
            if isCurrentWorkCancellation(error) { return false }
            statusMessage = "输出刷新失败，请查看错误详情"
            presentedError = "刷新模块输出失败：\(error.localizedDescription)"
            return false
        }
    }

    func writeCombinedModule(_ components: [(RelayModule, String)], generation: Int) async throws -> Bool {
        try checkCurrentWorkCancellation()
        let merged = try await processingWorker.merge(
            components,
            engineRevision: upstreamState.revision
        )
        guard shouldContinueCurrentWork(generation: generation) else { return false }
        try await fileStore.writeCombined(merged)
        guard shouldContinueCurrentWork(generation: generation) else { return false }
        try await publishCurrentFiles(combinedData: Data(merged.utf8), includeAssets: false)
        return true
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

    func publishedFiles(
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
            applyingModuleMetadata: { [processingWorker] name, category, desc, iconURL, content in
                await processingWorker.applyingModuleMetadata(
                    name: name,
                    category: category,
                    desc: desc,
                    iconURL: iconURL,
                    to: content
                )
            },
            cancellationCheckpoint: {
                try checkCurrentWorkCancellation()
                try Task.checkCancellation()
            }
        )
    }

    private func currentPublishedFiles(
        combinedData: Data?,
        includeAssets: Bool,
        destination: PublishDestination
    ) async throws -> [PublishFile] {
        let plan = PublishCoordinator.plan(
            modules: modules,
            combinedModuleEnabled: settings.combinedModuleEnabled,
            destination: destination
        )
        return try await publishedFiles(
            plan: plan,
            combinedData: combinedData,
            includeAssets: includeAssets,
            destination: destination
        )
    }

    /// 收集所选本地模块的独立输出文件（不包含总模块）。
    func selectedLocalPublishedFiles(moduleIDs: Set<UUID>) async throws -> [PublishFile] {
        let plan = PublishCoordinator.selectedPlan(
            modules: modules,
            moduleIDs: moduleIDs,
            combinedModuleEnabled: settings.combinedModuleEnabled,
            destination: .local
        )
        return try await publishedFiles(
            plan: plan,
            combinedData: nil,
            includeAssets: true,
            destination: .local
        )
    }

    /// 将所选本地模块写入本地发布根目录，并把这些文件合并进已发布路径清单，不删除其他已发布文件。
    func publishSelectedLocalFiles(_ files: [PublishFile]) async throws {
        let target = settings.localModuleDirectory
        let plan = LocalPublishedFilesPlanner.plan(
            files: files,
            targetDirectory: target,
            previousRootDirectory: settings.localPublishedRootDirectory,
            previousPublishedPaths: settings.localPublishedFilePaths
        )
        _ = try await fileStore.exportPublishedFiles(
            files,
            toRootDirectory: target,
            removingObsoleteRelativePaths: [],
            knownManagedRelativePaths: plan.knownManagedPaths
        )
        let mergedPaths = Array(Set(plan.knownManagedPaths).union(plan.currentPaths)).sorted()
        settings.localPublishedRootDirectory = target
        settings.localPublishedFilePaths = mergedPaths
        saveSettings()
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
}
