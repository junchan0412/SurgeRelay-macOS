import Foundation

/// 删除本地模块时的处理深度。
enum ModuleDeletionMode: Sendable {
    /// 仅从管理列表移除，保留磁盘上的输出文件。
    case removeFromList
    /// 移除并清理受 Surge Relay 管理的输出文件（自写源文件保留）。
    case clearOutput
    /// 彻底删除：连磁盘上的输出/源文件一并删除（需用户明确确认）。
    case deleteAll
}

@MainActor
extension AppModel {
    func addModule(from draft: ModuleDraft) throws {
        guard !isWorking else { throw PreviewContentSaveError.busy }
        let plan = try ModuleDraftPlanner.addPlan(
            from: draft,
            modules: modules,

            localModuleDirectory: settings.localModuleDirectory
        )
        let module = plan.module
        registerLocalChange()
        modules.append(module)
        invalidateModuleSummaryCache()
        selectedModuleID = module.id
        if let customIconURL = plan.customIconURL, let url = URL(string: customIconURL) {
            Task { try? await iconStore.cacheIcon(from: url, for: module.id, force: true) }
        }
        try persistModules()
        refreshLocalSourceWatching()
        statusMessage = AppRuntimeOptions.isUIQAMode
            ? "已添加 \(module.name)；UI QA 模式未启动自动更新"
            : "已添加 \(module.name)，即将自动更新"
        scheduleAutomaticUpdate(moduleID: module.id)
    }

    func updateModule(id: UUID, from draft: ModuleDraft) throws {
        guard !isWorking else { throw PreviewContentSaveError.busy }
        guard let index = modules.firstIndex(where: { $0.id == id }) else { return }
        guard let plan = try ModuleDraftPlanner.updatePlan(
            id: id,
            from: draft,
            modules: modules,

            localModuleDirectory: settings.localModuleDirectory
        ) else {
            return
        }
        guard plan.hasChanges else {
            statusMessage = "没有需要保存的更改"
            return
        }
        registerLocalChange()
        modules[index] = plan.module
        if let adoptedPath = plan.adoptedLocalPublishedPath {
            let localPlan = LocalPublishedFilesPlanner.plan(files: [], targetDirectory: settings.localModuleDirectory,
                previousRootDirectory: settings.localPublishedRootDirectory, previousPublishedPaths: settings.localPublishedFilePaths)
            settings.localPublishedRootDirectory = localPlan.targetDirectory
            settings.localPublishedFilePaths = LocalPublishedFilesPlanner.mergedPaths(localPlan.knownManagedPaths, adding: [adoptedPath])
            saveSettings()
        }
        invalidateModuleSummaryCache()
        if plan.sourceChanged || plan.customIconChanged {
            if let customIconURL = plan.customIconURL, let url = URL(string: customIconURL) {
                Task { try? await iconStore.cacheIcon(from: url, for: id, force: true) }
            } else {
                Task { try? await iconStore.removeIcon(for: id) }
            }
        }
        try persistModules()
        refreshLocalSourceWatching()
        statusMessage = if plan.sourceChanged, AppRuntimeOptions.isUIQAMode {
            "已保存 \(modules[index].name)；UI QA 模式未启动自动更新"
        } else if plan.sourceChanged {
            "已保存 \(modules[index].name)，即将自动更新"
        } else {
            "已保存 \(modules[index].name)，正在刷新输出"
        }
        if !plan.sourceChanged { restartScheduler() }
        if plan.sourceChanged, shouldUpdateModule(modules[index]) {
            scheduleAutomaticUpdate(moduleID: id)
        } else {
            Task { await refreshModuleOutputs(moduleIDs: [id]) }
        }
        if plan.customIconChanged, plan.customIconURL == nil, !plan.sourceChanged {
            Task { await refreshModuleMetadataFromCache() }
        }
    }

    func deleteModule(id: UUID, mode: ModuleDeletionMode = .clearOutput) async {
        guard !isWorking else { statusMessage = PreviewContentSaveError.busy.localizedDescription; return }
        guard let index = modules.firstIndex(where: { $0.id == id }) else { return }
        let module = modules[index]
        beginWork(.savingPreview)
        workActivity.title = "删除模块"
        defer { endWork(.savingPreview) }
        let protectedPaths = Set(localProtectedSourcePaths(targetDirectory: settings.localModuleDirectory)
            .map(LocalSourcePathResolver.pathIdentity))
        do {
            if module.hasLocalStorageTarget {
                switch mode {
                case .removeFromList:
                    break
                case .clearOutput:
                    if !protectedPaths.contains(LocalSourcePathResolver.pathIdentity(module.publishedRelativePath)) {
                        try await fileStore.removePublishedFile(relativePath: module.publishedRelativePath,
                            rootDirectoryPath: settings.localModuleDirectory)
                    }
                case .deleteAll:
                    try await fileStore.removePublishedFileForcing(relativePath: module.publishedRelativePath,
                        rootDirectoryPath: settings.localModuleDirectory)
                }
            }
        } catch {
            presentedError = "删除模块文件失败：\(error.localizedDescription)"
            statusMessage = "删除未完成，模块仍保留在管理列表"
            return
        }
        registerLocalChange()
        let localPlan = LocalPublishedFilesPlanner.plan(files: [], targetDirectory: settings.localModuleDirectory,
            previousRootDirectory: settings.localPublishedRootDirectory,
            previousPublishedPaths: settings.localPublishedFilePaths,
            protectedSourcePaths: Array(protectedPaths))
        if settings.localPublishedFilePaths != localPlan.knownManagedPaths {
            settings.localPublishedFilePaths = localPlan.knownManagedPaths
            saveSettings()
        }
        modules.removeAll { $0.id == id }
        modulePreviewDrafts.removeValue(forKey: id)
        invalidateModuleSummaryCache()
        try? await fileStore.removeComponent(id: id)
        try? await fileStore.removeAssets(id: id)
        try? await iconStore.removeIcon(for: id)
        try? persistModules()
        refreshLocalSourceWatching()
        selectedModuleID = modules.first?.id
        let rebuiltOutput = true
        do { try await flushPersistence() }
        catch { statusMessage = "模块已从内存移除，但删除记录尚未保存到磁盘"; return }
        if rebuiltOutput { statusMessage = "已删除 \(module.name)，输出已刷新" }
        restartScheduler()
    }

    /// 复制一个模块：保留来源与全部设置，名称与输出文件名按唯一规则生成副本。
    func duplicateModule(id: UUID) throws {
        guard !isWorking else { throw PreviewContentSaveError.busy }
        guard let index = modules.firstIndex(where: { $0.id == id }) else { return }
        let source = modules[index]
        var draft = ModuleDraft(module: source)
        draft.name = ModuleNamingPlanner.duplicateName(base: source.name, existing: modules.map(\.name))
        let outputFileName = ModuleNamingPlanner.uniqueOutputFileName(
            for: draft,
            source: draft.sourceURL,
            modules: modules
        )
        var copy = source
        copy.id = UUID()
        copy.name = draft.name
        copy.outputFileName = outputFileName
        copy.createdAt = .now
        copy.lastUpdatedAt = nil
        copy.contentHash = nil
        copy.sourceETag = nil
        copy.sourceLastModified = nil
        copy.sourceContentHash = nil
        copy.sourceCheckedAt = nil
        copy.state = .never
        copy.lastError = nil
        copy.localOutputError = nil
        if copy.hasLocalStorageTarget {
            copy.localStorageRelativePath = copy.publishedRelativePath
            copy.preservesOutputFileName = true
        }
        registerLocalChange()
        modules.append(copy)
        invalidateModuleSummaryCache()
        selectedModuleID = copy.id
        try persistModules()
        refreshLocalSourceWatching()
        statusMessage = "已复制 \(source.name) 为 \(copy.name)"
        scheduleAutomaticUpdate(moduleID: copy.id)
    }

    func refreshModuleMetadataFromCache() async {
        var changed = false
        for moduleValue in modules {
            let localModuleDirectory = settings.localModuleDirectory
            let localMetadata = await Task.detached(priority: .utility) {
                LocalModuleMetadataReader.snapshot(
                    for: moduleValue,
                    rootDirectoryPath: localModuleDirectory
                )
            }.value
            var moduleForPlanning = moduleValue
            if let localMetadata,
               moduleForPlanning.localStorageRelativePath != localMetadata.localStorageRelativePath {
                let previousLocalPath = moduleForPlanning.localStorageRelativePath
                let followsLocalPath = previousLocalPath.map {
                    LocalSourcePathResolver.pathIdentity($0) ==
                        LocalSourcePathResolver.pathIdentity(moduleForPlanning.publishedRelativePath)
                } ?? true
                moduleForPlanning.localStorageRelativePath = localMetadata.localStorageRelativePath
                moduleForPlanning.storageTargets.insert(.local)
                moduleForPlanning.preservesOutputFileName = true
                if followsLocalPath {
                    let components = localMetadata.localStorageRelativePath.split(separator: "/")
                    moduleForPlanning.outputFolder = components.dropLast().joined(separator: "/")
                    if let fileName = components.last { moduleForPlanning.outputFileName = String(fileName) }
                }
                changed = true
            }
            guard let content = try? await fileStore.readComponent(id: moduleValue.id) else {
                if let subscription = localMetadata?.scriptHubSubscription,
                   moduleForPlanning.reconcileScriptHubSubscriptionMetadata(subscription) {
                    changed = true
                }
                if moduleForPlanning != moduleValue { replace(moduleForPlanning) }
                continue
            }
            let hasOverride = await fileStore.hasOverride(id: moduleValue.id)
            let convertedContent = hasOverride
                ? try? await fileStore.readConvertedComponent(id: moduleValue.id)
                : nil
            let detectedIcon = await processingWorker.iconURL(
                in: content,
                relativeTo: moduleForPlanning.updateSourceURL
            )
            let plan = ModuleMetadataRefreshPlanner.plan(
                module: moduleForPlanning,
                cachedContent: content,
                convertedContent: convertedContent,
                authoritativeSubscription: localMetadata?.scriptHubSubscription,
                hasOverride: hasOverride,
                detectedIconURL: detectedIcon
            )
            if plan.isChanged || plan.module != moduleValue {
                replace(plan.module)
                changed = true
            }
            if let preferredIcon = plan.preferredIconURL {
                try? await iconStore.cacheIcon(
                    from: preferredIcon,
                    for: plan.module.id,
                    force: plan.shouldRefreshIconCache
                )
            } else {
                try? await iconStore.removeIcon(for: plan.module.id)
            }
        }
        if changed {
            try? persistModules()
            try? await flushPersistence()
        }
    }

    func setModuleArgument(moduleID: UUID, key: String, value: String, defaultValue: String) {
        guard !isWorking else { statusMessage = PreviewContentSaveError.busy.localizedDescription; return }
        guard let index = modules.firstIndex(where: { $0.id == moduleID }) else { return }
        guard let plan = ModuleArgumentPlanner.setOverride(
            module: modules[index],
            key: key,
            value: value,
            defaultValue: defaultValue
        ) else { return }
        registerLocalChange()
        modules[index].argumentOverrides = plan.overrides
        try? persistModules()
        statusMessage = plan.statusMessage
        Task { await refreshModuleOutputs(moduleIDs: [moduleID]) }
    }

    func resetModuleArguments(moduleID: UUID) {
        guard !isWorking else { statusMessage = PreviewContentSaveError.busy.localizedDescription; return }
        guard let index = modules.firstIndex(where: { $0.id == moduleID }),
              let plan = ModuleArgumentPlanner.resetOverrides(module: modules[index]) else { return }
        registerLocalChange()
        modules[index].argumentOverrides = plan.overrides
        try? persistModules()
        statusMessage = plan.statusMessage
        Task { await refreshModuleOutputs(moduleIDs: [moduleID]) }
    }

    func replace(_ module: RelayModule) {
        guard let index = modules.firstIndex(where: { $0.id == module.id }) else { return }
        modules[index] = module
        invalidateModuleSummaryCache()
    }

    func setState(id: UUID, state: ModuleUpdateState, error: String?) {
        guard let index = modules.firstIndex(where: { $0.id == id }) else { return }
        // Skip no-op writes so Observation does not fan out identical list updates.
        if modules[index].state == state, modules[index].lastError == error {
            return
        }
        modules[index].state = state
        modules[index].lastError = error
        invalidateModuleSummaryCache()
    }

    func persistModules() throws {
        if defersModulePersistence { return }
        enqueueConfiguration(modules, fileName: "modules.json")
    }

    func persistModulesIfNeeded(force: Bool = false) throws {
        if defersModulePersistence, !force { return }
        enqueueConfiguration(modules, fileName: "modules.json")
    }

    func persistModulesIfNeededIgnoringErrors(force: Bool = false) {
        try? persistModulesIfNeeded(force: force)
    }

    private func scheduleAutomaticUpdate(moduleID: UUID) {
        guard workspaceIsActive, !isWorkspaceTransitioning, !startupRecoveryPending, !startupRecoveryFailed, !AppRuntimeOptions.isUIQAMode else { return }
        automaticUpdateTask?.cancel()
        automaticUpdateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            while self.isWorking, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            await self.updateAll(only: [moduleID])
        }
    }

    func registerLocalChange() {
        localChangeGeneration &+= 1
        moduleUpdateTask?.cancel()
        updatePreparationTask?.cancel()
        cancelAutomaticPublishSchedule()
        pendingPublishPreview = nil
    }
}
