import Foundation

@MainActor
extension AppModel {
    @discardableResult
    func refreshModuleOutputs(moduleIDs: Set<UUID>? = nil, schedulesAutomaticPublish: Bool = true) async -> Bool {
        let generation = localChangeGeneration
        let selected = modules.filter { moduleIDs?.contains($0.id) ?? true }
        var failures = 0
        if settings.publishToLocal {
            for module in selected where module.hasLocalStorageTarget && settings.isLocalPublishingEnabled(for: module.outputFormat) {
                guard shouldContinueCurrentWork(generation: generation) else { return false }
                do {
                    let files = try await selectedLocalPublishedFiles(moduleIDs: [module.id])
                    guard shouldContinueCurrentWork(generation: generation) else { return false }
                    try await publishSelectedLocalFiles(files, outputFormat: module.outputFormat)
                    if let index = modules.firstIndex(where: { $0.id == module.id }) { modules[index].localOutputError = nil }
                } catch {
                    if isCurrentWorkCancellation(error) { return false }
                    failures += 1
                    if let index = modules.firstIndex(where: { $0.id == module.id }) {
                        modules[index].localOutputError = error.localizedDescription
                    }
                    recordHistory([UpdateHistoryEntry(moduleID: module.id, moduleName: module.name, outcome: .failed,
                        duration: 0, message: "本地输出失败：\(error.localizedDescription)", publishDestination: .local)])
                }
            }
        }
        guard shouldContinueCurrentWork(generation: generation) else { return false }
        try? persistModules()
        if schedulesAutomaticPublish { scheduleAutomaticPublish() }
        if failures > 0 { statusMessage = "\(failures) 个模块本地输出失败，其他模块已分别处理" }
        return failures == 0
    }

    func cleanupLegacyOutputFiles() async {
        let paths = legacyPublishedRelativePaths()
        for directory in legacyOutputCleanupDirectories() {
            _ = try? await fileStore.removeLegacyPublishedFiles(in: directory, relativePaths: paths)
        }
    }

    func publishedFiles(
        plan: PublishPlan,
        includeAssets: Bool,
        destination: PublishDestination
    ) async throws -> [PublishFile] {
        let plans: [(PublishPlan, String)]
        if destination == .local {
            plans = ModuleOutputFormat.allCases.compactMap { format in
                let selection = plan.standaloneModules.filter { $0.outputFormat == format && settings.isLocalPublishingEnabled(for: format) }
                return selection.isEmpty ? nil : (PublishPlan(standaloneModules: selection), settings.localModuleDirectory(for: format))
            }
        } else {
            plans = [(plan, settings.localModuleDirectory)]
        }
        var result: [PublishFile] = []
        for (selection, directory) in plans {
            result.append(contentsOf: try await PublishFileAssembler.files(
            request: PublishFileAssemblyRequest(
                plan: selection,

                includeAssets: includeAssets,
                destination: destination,
                localModuleDirectory: directory
            ),
            readComponent: { [fileStore] id in
                try? await fileStore.readComponent(id: id)
            },
            generatedAssetFiles: { [fileStore] ids in
                try await fileStore.generatedAssetFiles(for: ids)
            },
            materialize: { [processingWorker] content, overrides in
                await processingWorker.configurableContent(content, overrides: overrides)
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
        ))
        }
        return result
    }

    func writeLocalModuleOutput(moduleID: UUID) async throws {
        guard !isWorking else { throw PreviewContentSaveError.busy }
        guard let module = modules.first(where: { $0.id == moduleID }) else { throw RelayError.moduleMissing }
        let format = module.outputFormat
        guard settings.isLocalPublishingEnabled(for: format) else { throw RelayError.invalidOutput("请先开启 \(format.title) 本地存储。") }
        let target = settings.localModuleDirectory(for: format)
        let generation = localChangeGeneration
        beginWork(.publishing)
        workActivity.title = "写入本地文件"
        defer { endWork(.publishing) }
        let files = try await selectedLocalPublishedFiles(moduleIDs: [moduleID])
        guard !files.isEmpty else { throw RelayError.noFilesToPublish }
        let issues = await Task.detached { ModuleLintPlanner.check(files: files) }.value
        try ModuleLintPlanner.throwIfBlocking(issues)
        try checkLocalPublishContext(target: target, generation: generation, outputFormat: format)
        try enterNonCancellableWorkPhase(statusMessage: "正在写入本地文件…")
        try await publishSelectedLocalFiles(files, outputFormat: format)
        if let index = modules.firstIndex(where: { $0.id == moduleID }) { modules[index].localOutputError = nil }
        try persistModules()
        presentedError = nil
        statusMessage = "已写入本地文件"
    }

    func prepareLocalOutputAdoption(moduleID: UUID) async throws -> LocalOutputAdoptionReview {
        guard !isWorking else { throw PreviewContentSaveError.busy }
        guard let module = modules.first(where: { $0.id == moduleID }), module.hasRemoteUpdateSource,
              settings.isLocalPublishingEnabled(for: module.outputFormat),
              PublishCoordinator.shouldPublishStandalone(module, destination: .local) else {
            throw RelayError.invalidOutput("请选择需要写入本地的订阅模块。")
        }
        let target = settings.localModuleDirectory(for: module.outputFormat)
        let generation = localChangeGeneration
        let path = module.publishedRelativePath
        guard !localProtectedSourcePaths(targetDirectory: target, outputFormat: module.outputFormat).map(LocalSourcePathResolver.pathIdentity)
            .contains(LocalSourcePathResolver.pathIdentity(path)) else {
            throw RelayError.invalidOutput("该路径仍是已登记的本地来源，不能接管。")
        }
        beginWork(.publishing)
        workActivity.title = "比较本地输出"
        defer { endWork(.publishing) }
        guard let original = try await fileStore.readPublishedFile(relativePath: path, rootDirectoryPath: target),
              original.count <= 20 * 1024 * 1024,
              let originalText = String(data: original, encoding: .utf8),
              ManagedPublishedFile.canAdopt(original, relativePath: path) else {
            throw RelayError.invalidOutput("文件已不存在、已受管或不适合接管，请重新检查。")
        }
        let files = try await selectedLocalPublishedFiles(moduleIDs: [moduleID])
        guard let output = files.first(where: { $0.name == path }),
              let outputText = String(data: output.data, encoding: .utf8) else { throw RelayError.noFilesToPublish }
        let issues = await Task.detached { ModuleLintPlanner.check(files: files) }.value
        try ModuleLintPlanner.throwIfBlocking(issues)
        let diff = await Task.detached { ModuleLineDiffPlanner.compare(local: originalText, github: outputText) }.value
        try checkLocalPublishContext(target: target, generation: generation, outputFormat: module.outputFormat)
        return LocalOutputAdoptionReview(moduleID: moduleID, targetDirectory: target, relativePath: path,
            expectedExistingHash: original.sha256String, generation: generation, files: files, diff: diff)
    }

    func confirmLocalOutputAdoption(_ review: LocalOutputAdoptionReview) async throws {
        guard !isWorking else { throw PreviewContentSaveError.busy }
        guard let module = modules.first(where: { $0.id == review.moduleID }), module.hasRemoteUpdateSource,
              settings.isLocalPublishingEnabled(for: module.outputFormat),
              module.publishedRelativePath == review.relativePath,
              PublishCoordinator.shouldPublishStandalone(module, destination: .local) else { throw PreviewContentSaveError.changed }
        try checkLocalPublishContext(target: review.targetDirectory, generation: review.generation, outputFormat: module.outputFormat)
        beginWork(.publishing)
        workActivity.title = "接管本地输出"
        defer { endWork(.publishing) }
        let current = try await selectedLocalPublishedFiles(moduleIDs: [review.moduleID])
        guard current.map({ $0.name + ":" + $0.data.sha256String })
                == review.files.map({ $0.name + ":" + $0.data.sha256String }) else { throw PreviewContentSaveError.changed }
        let issues = await Task.detached { ModuleLintPlanner.check(files: current) }.value
        try ModuleLintPlanner.throwIfBlocking(issues)
        try checkLocalPublishContext(target: review.targetDirectory, generation: review.generation, outputFormat: module.outputFormat)
        try enterNonCancellableWorkPhase(statusMessage: "正在备份并接管本地文件…")
        let backup = try await fileStore.adoptLocalPublishedFile(relativePath: review.relativePath,
            rootDirectoryPath: review.targetDirectory, moduleID: review.moduleID,
            expectedExistingHash: review.expectedExistingHash,
            protectedSourcePaths: localProtectedSourcePaths(targetDirectory: review.targetDirectory, outputFormat: module.outputFormat))
        try checkLocalPublishContext(target: review.targetDirectory, generation: review.generation, outputFormat: module.outputFormat)
        try await publishSelectedLocalFiles(current, outputFormat: module.outputFormat)
        if let index = modules.firstIndex(where: { $0.id == review.moduleID }) { modules[index].localOutputError = nil }
        try persistModules()
        presentedError = nil
        statusMessage = "已接管并更新本地文件；原文件备份：\(backup.path)"
        recordHistory([UpdateHistoryEntry(moduleID: module.id, moduleName: module.name, outcome: .published,
            duration: 0, message: statusMessage, publishedFiles: current.map(\.name), publishDestination: .local)])
    }

    /// 收集所选本地模块及其脚本资源。
    func selectedLocalPublishedFiles(moduleIDs: Set<UUID>) async throws -> [PublishFile] {
        let plan = PublishCoordinator.selectedPlan(
            modules: modules,
            moduleIDs: moduleIDs,

            destination: .local
        )
        return try await publishedFiles(
            plan: plan,
            includeAssets: true,
            destination: .local
        )
    }

    /// 将所选本地模块写入本地发布根目录，并把这些文件合并进已发布路径清单，不删除其他已发布文件。
    func publishSelectedLocalFiles(_ files: [PublishFile], expectedExistingHashes: [String: String] = [:], outputFormat: ModuleOutputFormat? = nil) async throws {
        guard let outputFormat else {
            for (format, selection) in localPublishedFileGroups(files) {
                let paths = Set(selection.map(\.name))
                try await publishSelectedLocalFiles(selection, expectedExistingHashes: expectedExistingHashes.filter { paths.contains($0.key) }, outputFormat: format)
            }
            return
        }
        guard settings.isLocalPublishingEnabled(for: outputFormat) else { throw RelayError.invalidOutput("请先开启 \(outputFormat.title) 本地存储。") }
        let target = settings.localModuleDirectory(for: outputFormat)
        let generation = localChangeGeneration
        let issues = await Task.detached { ModuleLintPlanner.check(files: files) }.value
        try ModuleLintPlanner.throwIfBlocking(issues)
        try checkLocalPublishContext(target: target, generation: generation, outputFormat: outputFormat)
        try await reconcileRecoveredLocalResources(outputFormat: outputFormat)
        try checkLocalPublishContext(target: target, generation: generation, outputFormat: outputFormat)
        let plan = LocalPublishedFilesPlanner.plan(
            files: files,
            targetDirectory: target,
            previousRootDirectory: settings.localStorage(for: outputFormat).publishedRootDirectory,
            previousPublishedPaths: settings.localStorage(for: outputFormat).publishedFilePaths,
            protectedSourcePaths: localProtectedSourcePaths(targetDirectory: target, outputFormat: outputFormat)
        )
        if expectedExistingHashes.isEmpty {
            try await repairRelocatedLocalOutputs(files: files, knownPaths: plan.knownManagedPaths,
                target: target, generation: generation, outputFormat: outputFormat)
        }
        do {
            let recorder = StageMetricsContext.current ?? StageMetricsRecorder()
            _ = try await recorder.measure(.publish, reason: "本地", bytes: { paths in
                (nil, Int64(files.filter { paths.contains($0.name) }.reduce(0) { $0 + $1.data.count }))
            }) {
                try await fileStore.exportPublishedFiles(files, toRootDirectory: target,
                    removingObsoleteRelativePaths: [], knownManagedRelativePaths: plan.knownManagedPaths,
                    expectedExistingHashes: expectedExistingHashes,
                    protectedSourcePaths: localProtectedSourcePaths(targetDirectory: target, outputFormat: outputFormat))
            }
        } catch let failure as LocalPublishPartialFailure {
            try await retainPartialLocalPublish(failure.writtenPaths, target: target,
                generation: generation, knownPaths: plan.knownManagedPaths, outputFormat: outputFormat)
            throw failure

        }
        try checkLocalPublishContext(target: target, generation: generation, outputFormat: outputFormat)
        let retiredPaths = try await retireMovedLocalOutputs(files: files, knownPaths: plan.knownManagedPaths,
            target: target, generation: generation, outputFormat: outputFormat)
        let retired = Set(retiredPaths.map(LocalSourcePathResolver.pathIdentity))
        let mergedPaths = LocalPublishedFilesPlanner.mergedPaths(plan.knownManagedPaths, adding: plan.currentPaths)
            .filter { !retired.contains(LocalSourcePathResolver.pathIdentity($0)) }
        var storage = settings.localStorage(for: outputFormat)
        storage.publishedRootDirectory = plan.targetDirectory
        storage.publishedFilePaths = mergedPaths
        settings.setLocalStorage(storage, for: outputFormat)
        saveSettings()
        try await flushPersistence()
        try checkLocalPublishContext(target: target, generation: generation, outputFormat: outputFormat)
        try await fileStore.acknowledgePublishedResources(paths: plan.currentPaths, rootDirectoryPath: target)
    }

    private func retireMovedLocalOutputs(files: [PublishFile], knownPaths: [String], target: String, generation: Int, outputFormat: ModuleOutputFormat) async throws -> [String] {
        guard let root = LocalSourcePathResolver.canonicalDirectoryURL(for: target) else { return [] }
        let published = Set(files.map { LocalSourcePathResolver.pathIdentity($0.name) })
        let protected = localProtectedSourcePaths(targetDirectory: target, outputFormat: outputFormat)
        var retired: [String] = []
        var completed: [UUID: Set<LocalOutputRetirement>] = [:]
        for module in modules where module.hasLocalStorageTarget && module.outputFormat == outputFormat && published.contains(LocalSourcePathResolver.pathIdentity(module.publishedRelativePath)) {
            var retirements = module.pendingLocalOutputRetirements.filter { $0.rootDirectory == root.path }
            if module.hasRemoteUpdateSource {
                for oldPath in knownPaths where !published.contains(LocalSourcePathResolver.pathIdentity(oldPath)) &&
                    (oldPath as NSString).lastPathComponent == (module.publishedRelativePath as NSString).lastPathComponent {
                    guard !retirements.contains(where: { LocalSourcePathResolver.pathIdentity($0.relativePath) == LocalSourcePathResolver.pathIdentity(oldPath) }),
                          let data = try await fileStore.readPublishedFile(relativePath: oldPath, rootDirectoryPath: target),
                          ManagedPublishedFile.isManaged(data, relativePath: oldPath),
                          let text = String(data: data, encoding: .utf8),
                          let subscription = ModuleMetadataParser.scriptHubSubscription(in: text),
                          ModuleSourceIdentity.matches(subscription.originalURL, module.updateSourceURL) else { continue }
                    retirements.append(LocalOutputRetirement(rootDirectory: root.path, relativePath: oldPath, contentHash: data.sha256String))
                }
            }
            for item in retirements {
                let identity = LocalSourcePathResolver.pathIdentity(item.relativePath)
                if identity == LocalSourcePathResolver.pathIdentity(module.publishedRelativePath) {
                    completed[module.id, default: []].insert(item)
                    continue
                }
                guard !published.contains(identity), !protected.map(LocalSourcePathResolver.pathIdentity).contains(identity),
                      !modules.contains(where: { other in
                          other.id != module.id && other.hasLocalStorageTarget && localStorageRootMatches(other.outputFormat, target: target) &&
                            [other.publishedRelativePath, other.localStorageRelativePath].compactMap { $0 }
                                .contains { LocalSourcePathResolver.pathIdentity($0) == identity }
                      }) else { continue }
                try checkLocalPublishContext(target: target, generation: generation, outputFormat: outputFormat)
                let existing = try await fileStore.readPublishedFile(relativePath: item.relativePath, rootDirectoryPath: target)
                if let existing {
                    guard let hash = item.contentHash, existing.sha256String == hash,
                          ManagedPublishedFile.isManaged(existing, relativePath: item.relativePath) else {
                        throw RelayError.invalidOutput("新位置已写入；旧文件 \(item.relativePath) 在移动后变化或不属于本模块受管输出，已保留，请核对后清理。")
                    }
                    _ = try await fileStore.exportPublishedFiles([], toRootDirectory: target,
                        removingObsoleteRelativePaths: [item.relativePath], expectedExistingHashes: [item.relativePath: hash],
                        protectedSourcePaths: protected)
                }
                try checkLocalPublishContext(target: target, generation: generation, outputFormat: outputFormat)
                retired.append(item.relativePath)
                completed[module.id, default: []].insert(item)
            }
        }
        for index in modules.indices {
            guard let items = completed[modules[index].id] else { continue }
            modules[index].pendingLocalOutputRetirements.removeAll { items.contains($0) }
        }
        try persistModules()
        return retired
    }

    private func repairRelocatedLocalOutputs(files: [PublishFile], knownPaths: [String], target: String, generation: Int, outputFormat: ModuleOutputFormat) async throws {
        let publishedPaths = Set(files.map { LocalSourcePathResolver.pathIdentity($0.name) })
        let known = Set(knownPaths.map(LocalSourcePathResolver.pathIdentity))
        let protected = localProtectedSourcePaths(targetDirectory: target, outputFormat: outputFormat)
        for module in modules where module.hasLocalStorageTarget && module.outputFormat == outputFormat && module.hasRemoteUpdateSource {
            let path = module.publishedRelativePath
            guard publishedPaths.contains(LocalSourcePathResolver.pathIdentity(path)),
                  let original = try await fileStore.readPublishedFile(relativePath: path, rootDirectoryPath: target),
                  let oldPath = ManagedPublishedFile.managedRelativePath(in: original),
                  !ManagedPublishedFile.isManaged(original, relativePath: path),
                  known.contains(LocalSourcePathResolver.pathIdentity(oldPath)),
                  LocalSourcePathResolver.pathIdentity((oldPath as NSString).lastPathComponent)
                    == LocalSourcePathResolver.pathIdentity((path as NSString).lastPathComponent),
                  !modules.contains(where: { other in
                      other.id != module.id && other.hasLocalStorageTarget && localStorageRootMatches(other.outputFormat, target: target) &&
                        [other.publishedRelativePath, other.localStorageRelativePath].compactMap { $0 }.contains {
                            LocalSourcePathResolver.pathIdentity($0) == LocalSourcePathResolver.pathIdentity(oldPath)
                        }
                  }),
                  !protected.map(LocalSourcePathResolver.pathIdentity).contains(LocalSourcePathResolver.pathIdentity(oldPath)),
                  let text = String(data: original, encoding: .utf8),
                  let subscription = ModuleMetadataParser.scriptHubSubscription(in: text),
                  ModuleSourceIdentity.matches(subscription.originalURL, module.updateSourceURL) else { continue }
            try checkLocalPublishContext(target: target, generation: generation, outputFormat: outputFormat)
            _ = try await fileStore.adoptLocalPublishedFile(relativePath: path, rootDirectoryPath: target,
                moduleID: module.id, expectedExistingHash: original.sha256String, protectedSourcePaths: protected)
            try checkLocalPublishContext(target: target, generation: generation, outputFormat: outputFormat)
        }
    }

    private func retainPartialLocalPublish(_ paths: [String], target: String, generation: Int, knownPaths: [String], outputFormat: ModuleOutputFormat) async throws {
        try checkLocalPublishContext(target: target, generation: generation, outputFormat: outputFormat)
        var storage = settings.localStorage(for: outputFormat)
        storage.publishedRootDirectory = LocalSourcePathResolver.canonicalDirectoryURL(for: target)?.path ?? target
        storage.publishedFilePaths = LocalPublishedFilesPlanner.mergedPaths(knownPaths, adding: paths)
        settings.setLocalStorage(storage, for: outputFormat)
        saveSettings()
        try await flushPersistence()
        try checkLocalPublishContext(target: target, generation: generation, outputFormat: outputFormat)
        try await fileStore.acknowledgePublishedResources(paths: paths, rootDirectoryPath: target)
    }

    func reconcileRecoveredLocalResources(outputFormat: ModuleOutputFormat? = nil) async throws {
        guard let outputFormat else {
            for format in ModuleOutputFormat.allCases where settings.isLocalPublishingEnabled(for: format) && !settings.localModuleDirectory(for: format).isEmpty {
                try await reconcileRecoveredLocalResources(outputFormat: format)
            }
            return
        }
        let target = settings.localModuleDirectory(for: outputFormat)
        let generation = localChangeGeneration
        guard settings.isLocalPublishingEnabled(for: outputFormat), !target.isEmpty else { return }
        let recovered = try await fileStore.recoverPublishedResourcePaths(rootDirectoryPath: target)
        try checkLocalPublishContext(target: target, generation: generation, outputFormat: outputFormat)
        guard !recovered.isEmpty else { return }
        var acknowledged: [String] = []
        for format in ModuleOutputFormat.allCases {
            let paths = recovered.filter { localOutputFormat(for: $0) == format }
            guard !paths.isEmpty else { continue }
            var storage = settings.localStorage(for: format)
            let recordedRoot = LocalSourcePathResolver.canonicalDirectoryURL(for: storage.publishedRootDirectory ?? "")
            let targetRoot = LocalSourcePathResolver.canonicalDirectoryURL(for: target)
            guard recordedRoot == targetRoot || localStorageRootMatches(format, target: target) else { continue }
            let plan = LocalPublishedFilesPlanner.plan(files: [], targetDirectory: target,
                previousRootDirectory: storage.publishedRootDirectory, previousPublishedPaths: storage.publishedFilePaths,
                protectedSourcePaths: localProtectedSourcePaths(targetDirectory: target, outputFormat: format))
            storage.publishedRootDirectory = plan.targetDirectory
            storage.publishedFilePaths = LocalPublishedFilesPlanner.mergedPaths(plan.knownManagedPaths, adding: paths)
            settings.setLocalStorage(storage, for: format)
            acknowledged.append(contentsOf: paths)
        }
        saveSettings()
        try await flushPersistence()
        try checkLocalPublishContext(target: target, generation: generation, outputFormat: outputFormat)
        try await fileStore.acknowledgePublishedResources(paths: acknowledged, rootDirectoryPath: target)
    }

    private func checkLocalPublishContext(target: String, generation: Int, outputFormat: ModuleOutputFormat) throws {
        guard workspaceIsActive, !isWorkspaceTransitioning,
              settings.isLocalPublishingEnabled(for: outputFormat), target == settings.localModuleDirectory(for: outputFormat), generation == localChangeGeneration else {
            throw CancellationError()
        }
    }

    func localCleanupReviewFingerprint(outputFormat: ModuleOutputFormat = .surge) -> String {
        let plan = PublishCoordinator.plan(modules: modules.filter { $0.outputFormat == outputFormat }, destination: .local)
        let paths = plan.standaloneModules.map { $0.id.uuidString + ":" + $0.publishedRelativePath }.sorted()
        let protectedPaths = localProtectedSourcePaths(targetDirectory: settings.localModuleDirectory(for: outputFormat), outputFormat: outputFormat)
            .map { "source:" + LocalSourcePathResolver.pathIdentity($0) }
        return Data(([String(localChangeGeneration)]
            + paths + protectedPaths).joined(separator: "\n").utf8).sha256String
    }

    func localProtectedSourcePaths(targetDirectory: String, outputFormat: ModuleOutputFormat? = nil) -> [String] {
        let sourcePaths = modules.compactMap { LocalSourcePathResolver.storageRelativePath(for: $0, rootDirectoryPath: targetDirectory) }
        let matching = modules.filter { localStorageRootMatches($0.outputFormat, target: targetDirectory) }
        var protected = sourcePaths + LocalPublishedFilesPlanner.protectedSourcePaths(modules: matching, targetDirectory: targetDirectory)
        if let outputFormat {
            let root = LocalSourcePathResolver.canonicalDirectoryURL(for: targetDirectory)
            let siblings = modules.filter { module in
                module.hasLocalStorageTarget && module.outputFormat != outputFormat &&
                    (localStorageRootMatches(module.outputFormat, target: targetDirectory) ||
                     LocalSourcePathResolver.canonicalDirectoryURL(for: settings.localStorage(for: module.outputFormat).publishedRootDirectory ?? "") == root)
            }
            protected.append(contentsOf: siblings.map(\.publishedRelativePath))
            let ids = Set(siblings.map(\.id))
            let tracked = ModuleOutputFormat.allCases.flatMap { format -> [String] in
                let storage = settings.localStorage(for: format)
                return LocalSourcePathResolver.canonicalDirectoryURL(for: storage.publishedRootDirectory ?? "") == root ? storage.publishedFilePaths : []
            }
            protected.append(contentsOf: tracked.filter { path in
                let components = path.split(separator: "/")
                return components.count > 2 && components[0] == "assets" &&
                    UUID(uuidString: String(components[1])).map { ids.contains($0) } == true
            })
        }
        return Array(Set(protected)).sorted()
    }

    func localPublishedFileGroups(_ files: [PublishFile]) -> [(ModuleOutputFormat, [PublishFile])] {
        ModuleOutputFormat.allCases.compactMap { format in
            let selection = files.filter { localOutputFormat(for: $0.name) == format }
            return selection.isEmpty ? nil : (format, selection)
        }
    }

    func localOutputFormat(for relativePath: String) -> ModuleOutputFormat {
        if let module = modules.first(where: { $0.publishedRelativePath == relativePath }) { return module.outputFormat }
        let components = relativePath.split(separator: "/")
        if components.count > 2, components[0] == "assets", let id = UUID(uuidString: String(components[1])),
           let module = modules.first(where: { $0.id == id }) { return module.outputFormat }
        return .surge
    }

    private func localStorageRootMatches(_ format: ModuleOutputFormat, target: String) -> Bool {
        LocalSourcePathResolver.canonicalDirectoryURL(for: settings.localModuleDirectory(for: format))
            == LocalSourcePathResolver.canonicalDirectoryURL(for: target)
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
            combinedModuleFileName: settings.legacyCombinedModuleFileName,

            managedEngineFileName: settings.managedEngineFileName
        )
    }
}
