import Foundation

@MainActor
extension AppModel {
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
            applyingModuleMetadata: { [processingWorker] name, category, iconURL, content in
                await processingWorker.applyingModuleMetadata(
                    name: name,
                    category: category,
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
        _ = try await fileStore.exportPublishedFiles(
            files,
            toRootDirectory: target,
            removingObsoleteRelativePaths: [],
            knownManagedRelativePaths: settings.localPublishedFilePaths
        )
        let mergedPaths = Array(Set(settings.localPublishedFilePaths).union(files.map(\.name))).sorted()
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
