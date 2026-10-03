import Foundation

@MainActor
extension AppModel {
    @discardableResult
    func rebuildCombinedFromCache(schedulesAutomaticPublish: Bool = true, exportsLocalOutput: Bool = true) async -> Bool {
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
                return await rebuildCombinedFromCache(schedulesAutomaticPublish: schedulesAutomaticPublish, exportsLocalOutput: exportsLocalOutput)
            }
            if enabled.isEmpty {
                try await fileStore.removeCombined()
                if exportsLocalOutput { try await publishCurrentFiles(combinedData: nil, includeAssets: false) }
            } else if !(try await writeCombinedModule(components, generation: rebuildGeneration, exportsLocalOutput: exportsLocalOutput)) {
                guard !workCancellationRequested, !Task.isCancelled else { return false }
                return await rebuildCombinedFromCache(schedulesAutomaticPublish: schedulesAutomaticPublish, exportsLocalOutput: exportsLocalOutput)
            }
            try checkCurrentWorkCancellation()
            guard rebuildGeneration == localChangeGeneration else {
                return await rebuildCombinedFromCache(schedulesAutomaticPublish: schedulesAutomaticPublish, exportsLocalOutput: exportsLocalOutput)
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

    func writeCombinedModule(_ components: [(RelayModule, String)], generation: Int, exportsLocalOutput: Bool = true) async throws -> Bool {
        try checkCurrentWorkCancellation()
        let ids = Set(components.map { $0.0.id })
        let sourceFiles = components.map { PublishFile(name: $0.0.publishedRelativePath, data: Data($0.1.utf8)) }
        let assets = try await fileStore.generatedAssetFiles(for: ids)
        let issues = await Task.detached { ModuleLintPlanner.check(files: sourceFiles + assets, ownedModuleIDs: ids) }.value
        try ModuleLintPlanner.throwIfBlocking(issues)
        guard shouldContinueCurrentWork(generation: generation) else { return false }
        let merged = try await processingWorker.merge(
            components,
            engineRevision: upstreamState.revision
        )
        guard shouldContinueCurrentWork(generation: generation) else { return false }
        try await fileStore.writeCombined(merged)
        guard shouldContinueCurrentWork(generation: generation) else { return false }
        if exportsLocalOutput { try await publishCurrentFiles(combinedData: Data(merged.utf8), includeAssets: false) }
        return true
    }

    func publishCurrentFiles(combinedData: Data?, includeAssets: Bool) async throws {
        if settings.publishToLocal {
            let generation = localChangeGeneration
            let target = settings.localModuleDirectory
            try await reconcileRecoveredLocalResources()
            let files = try await currentPublishedFiles(
                combinedData: combinedData,
                includeAssets: includeAssets,
                destination: .local
            )
            let ids = PublishCoordinator.plan(modules: modules, combinedModuleEnabled: settings.combinedModuleEnabled,
                destination: .local).assetModuleIDs
            let validationFiles = includeAssets ? files : files + (try await fileStore.generatedAssetFiles(for: ids))
            let issues = await Task.detached { ModuleLintPlanner.check(files: validationFiles, ownedModuleIDs: ids) }.value
            try ModuleLintPlanner.throwIfBlocking(issues)
            try checkCurrentWorkCancellation()
            guard generation == localChangeGeneration, target == settings.localModuleDirectory else { throw CancellationError() }
            let localPublishPlan = LocalPublishedFilesPlanner.plan(
                files: files,
                targetDirectory: settings.localModuleDirectory,
                previousRootDirectory: settings.localPublishedRootDirectory,
                previousPublishedPaths: settings.localPublishedFilePaths
            )
            do {
                let recorder = StageMetricsContext.current ?? StageMetricsRecorder()
                _ = try await recorder.measure(.publish, reason: "本地", bytes: { paths in
                    (nil, Int64(files.filter { paths.contains($0.name) }.reduce(0) { $0 + $1.data.count }))
                }) {
                    try await fileStore.exportPublishedFiles(files, toRootDirectory: localPublishPlan.targetDirectory,
                        removingObsoleteRelativePaths: [], knownManagedRelativePaths: localPublishPlan.knownManagedPaths)
                }
            } catch let failure as LocalPublishPartialFailure {
                try await retainPartialLocalPublish(failure.writtenPaths, target: localPublishPlan.targetDirectory,
                    knownPaths: localPublishPlan.knownManagedPaths)
                throw failure
            }
            switch LocalPublishedFilesPlanner.completion(afterExporting: localPublishPlan) {
            case .persisted(let rootDirectory, let filePaths):
                settings.localPublishedRootDirectory = rootDirectory
                settings.localPublishedFilePaths = filePaths
                if pendingPublishPreview?.destination == .local {
                    pendingPublishPreview = nil
                }
                saveSettings()
            case .requiresCleanup(var preview, let message):
                var hashes: [String: String] = [:]
                for path in preview.deletedFiles {
                    let data = try await fileStore.readPublishedFile(relativePath: path, rootDirectoryPath: localPublishPlan.targetDirectory)
                    hashes[path] = data?.sha256String ?? "<missing>"
                }
                preview.localExpectedHashes = hashes
                preview.localReviewFingerprint = localCleanupReviewFingerprint()
                settings.localPublishedRootDirectory = localPublishPlan.targetDirectory
                settings.localPublishedFilePaths = Array(Set(localPublishPlan.knownManagedPaths).union(localPublishPlan.currentPaths)).sorted()
                saveSettings()
                pendingPublishPreview = preview
                statusMessage = message
            }
            try await flushPersistence()
            try await fileStore.acknowledgePublishedResources(paths: localPublishPlan.currentPaths, rootDirectoryPath: target)
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
    func publishSelectedLocalFiles(_ files: [PublishFile], expectedExistingHashes: [String: String] = [:]) async throws {
        let issues = await Task.detached { ModuleLintPlanner.check(files: files) }.value
        try ModuleLintPlanner.throwIfBlocking(issues)
        let target = settings.localModuleDirectory
        try await reconcileRecoveredLocalResources()
        let plan = LocalPublishedFilesPlanner.plan(
            files: files,
            targetDirectory: target,
            previousRootDirectory: settings.localPublishedRootDirectory,
            previousPublishedPaths: settings.localPublishedFilePaths
        )
        do {
            let recorder = StageMetricsContext.current ?? StageMetricsRecorder()
            _ = try await recorder.measure(.publish, reason: "本地", bytes: { paths in
                (nil, Int64(files.filter { paths.contains($0.name) }.reduce(0) { $0 + $1.data.count }))
            }) {
                try await fileStore.exportPublishedFiles(files, toRootDirectory: target,
                    removingObsoleteRelativePaths: [], knownManagedRelativePaths: plan.knownManagedPaths,
                    expectedExistingHashes: expectedExistingHashes)
            }
        } catch let failure as LocalPublishPartialFailure {
            try await retainPartialLocalPublish(failure.writtenPaths, target: target, knownPaths: plan.knownManagedPaths)
            throw failure
        }
        let mergedPaths = Array(Set(plan.knownManagedPaths).union(plan.currentPaths)).sorted()
        settings.localPublishedRootDirectory = target
        settings.localPublishedFilePaths = mergedPaths
        saveSettings()
        try await flushPersistence()
        try await fileStore.acknowledgePublishedResources(paths: plan.currentPaths, rootDirectoryPath: target)
    }

    private func retainPartialLocalPublish(_ paths: [String], target: String, knownPaths: [String]) async throws {
        settings.localPublishedRootDirectory = target
        settings.localPublishedFilePaths = Array(Set(knownPaths).union(paths)).sorted()
        saveSettings()
        try await flushPersistence()
        try await fileStore.acknowledgePublishedResources(paths: paths, rootDirectoryPath: target)
    }

    func reconcileRecoveredLocalResources() async throws {
        let target = settings.localModuleDirectory
        guard !target.isEmpty else { return }
        let recovered = try await fileStore.recoverPublishedResourcePaths(rootDirectoryPath: target)
        guard !recovered.isEmpty else { return }
        guard workspaceIsActive, !isWorkspaceTransitioning, target == settings.localModuleDirectory else { throw CancellationError() }
        let known = settings.localPublishedRootDirectory == target ? settings.localPublishedFilePaths : []
        settings.localPublishedRootDirectory = target
        settings.localPublishedFilePaths = Array(Set(known).union(recovered)).sorted()
        saveSettings()
        try await flushPersistence()
        try await fileStore.acknowledgePublishedResources(paths: recovered, rootDirectoryPath: target)
    }

    func localCleanupReviewFingerprint() -> String {
        let plan = PublishCoordinator.plan(modules: modules, combinedModuleEnabled: settings.combinedModuleEnabled, destination: .local)
        let paths = plan.standaloneModules.map { $0.id.uuidString + ":" + $0.publishedRelativePath }.sorted()
        return Data(([String(localChangeGeneration), String(settings.combinedModuleEnabled), settings.combinedModuleFileName]
            + paths).joined(separator: "\n").utf8).sha256String
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
