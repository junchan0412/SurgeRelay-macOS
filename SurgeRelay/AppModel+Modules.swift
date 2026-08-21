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
        let plan = try ModuleDraftPlanner.addPlan(
            from: draft,
            modules: modules,
            combinedModuleFileName: settings.combinedModuleFileName,
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
        statusMessage = AppRuntimeOptions.isUIQAMode
            ? "已添加 \(module.name)；UI QA 模式未启动自动更新"
            : "已添加 \(module.name)，即将自动更新"
        scheduleAutomaticUpdate()
    }

    func updateModule(id: UUID, from draft: ModuleDraft) throws {
        guard let index = modules.firstIndex(where: { $0.id == id }) else { return }
        guard let plan = try ModuleDraftPlanner.updatePlan(
            id: id,
            from: draft,
            modules: modules,
            combinedModuleFileName: settings.combinedModuleFileName,
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
            if settings.localPublishedRootDirectory == settings.localModuleDirectory {
                settings.localPublishedFilePaths = Array(
                    Set(settings.localPublishedFilePaths).union([adoptedPath])
                ).sorted()
            } else {
                settings.localPublishedRootDirectory = settings.localModuleDirectory
                settings.localPublishedFilePaths = [adoptedPath]
            }
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
        statusMessage = if plan.sourceChanged, AppRuntimeOptions.isUIQAMode {
            "已保存 \(modules[index].name)；UI QA 模式未启动自动更新"
        } else if plan.sourceChanged {
            "已保存 \(modules[index].name)，即将自动更新"
        } else {
            "已保存 \(modules[index].name)，正在刷新输出"
        }
        if plan.sourceChanged, shouldUpdateModule(modules[index]) {
            scheduleAutomaticUpdate()
        } else {
            Task { await rebuildCombinedFromCache() }
        }
        if plan.customIconChanged, plan.customIconURL == nil, !plan.sourceChanged {
            Task { await refreshModuleMetadataFromCache() }
        }
    }

    func setModuleIncludedInCombined(id: UUID, included: Bool) {
        guard let index = modules.firstIndex(where: { $0.id == id }) else { return }
        guard modules[index].isIncludedInCombined != included else { return }
        registerLocalChange()
        modules[index].isIncludedInCombined = included
        invalidateModuleSummaryCache()
        try? persistModules()
        if settings.combinedModuleEnabled {
            statusMessage = included ? "已将 \(modules[index].name) 加入总模块" : "已将 \(modules[index].name) 从总模块移除"
        } else {
            statusMessage = included ? "已记录 \(modules[index].name) 将在开启总模块后加入" : "已记录 \(modules[index].name) 不加入总模块"
        }
        if included, shouldUpdateModule(modules[index]) {
            scheduleAutomaticUpdate()
        } else {
            Task { await rebuildCombinedFromCache() }
        }
    }

    func deleteModule(id: UUID, mode: ModuleDeletionMode = .clearOutput) async {
        guard let index = modules.firstIndex(where: { $0.id == id }) else { return }
        registerLocalChange()
        let module = modules.remove(at: index)
        invalidateModuleSummaryCache()
        try? await fileStore.removeComponent(id: id)
        try? await fileStore.removeAssets(id: id)
        try? await iconStore.removeIcon(for: id)
        // 本地模块按删除模式处理磁盘上的输出文件。
        if module.storageLocation == .local {
            switch mode {
            case .removeFromList:
                break
            case .clearOutput:
                if module.publishesStandalone {
                    try? await fileStore.removePublishedFile(
                        relativePath: module.publishedRelativePath,
                        rootDirectoryPath: settings.localModuleDirectory
                    )
                }
            case .deleteAll:
                try? await fileStore.removePublishedFileForcing(
                    relativePath: module.publishedRelativePath,
                    rootDirectoryPath: settings.localModuleDirectory
                )
            }
        }
        try? persistModules()
        selectedModuleID = modules.first?.id
        await rebuildCombinedFromCache()
        statusMessage = "已删除 \(module.name)，输出已刷新"
    }

    /// 复制一个模块：保留来源与全部设置，名称与输出文件名按唯一规则生成副本。
    func duplicateModule(id: UUID) throws {
        guard let index = modules.firstIndex(where: { $0.id == id }) else { return }
        let source = modules[index]
        var draft = ModuleDraft(module: source)
        draft.name = ModuleNamingPlanner.duplicateName(base: source.name, existing: modules.map(\.name))
        let outputFileName = ModuleNamingPlanner.uniqueOutputFileName(
            for: draft,
            source: draft.sourceURL,
            modules: modules,
            combinedModuleFileName: settings.combinedModuleFileName,
            excluding: source.id
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
        if copy.storageLocation == .local {
            copy.localStorageRelativePath = try ModuleNamingPlanner.localStorageRelativePath(
                storageLocation: .local,
                source: copy.sourceURL,
                outputFileName: outputFileName,
                outputFolder: ModuleOutputFolder.normalized(copy.outputFolder),
                localModuleDirectory: settings.localModuleDirectory
            )
            copy.preservesOutputFileName = true
        }
        registerLocalChange()
        modules.append(copy)
        invalidateModuleSummaryCache()
        selectedModuleID = copy.id
        try persistModules()
        statusMessage = "已复制 \(source.name) 为 \(copy.name)"
        scheduleAutomaticUpdate()
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
                moduleForPlanning.localStorageRelativePath = localMetadata.localStorageRelativePath
                moduleForPlanning.storageLocation = .local
                moduleForPlanning.preservesOutputFileName = true
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
        if changed { try? persistModules() }
    }

    func setModuleArgument(moduleID: UUID, key: String, value: String, defaultValue: String) {
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
        Task { await rebuildCombinedFromCache() }
    }

    func resetModuleArguments(moduleID: UUID) {
        guard let index = modules.firstIndex(where: { $0.id == moduleID }),
              let plan = ModuleArgumentPlanner.resetOverrides(module: modules[index]) else { return }
        registerLocalChange()
        modules[index].argumentOverrides = plan.overrides
        try? persistModules()
        statusMessage = plan.statusMessage
        Task { await rebuildCombinedFromCache() }
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
        try PersistenceStore.saveModules(modules)
    }

    func persistModulesIfNeeded(force: Bool = false) throws {
        if defersModulePersistence, !force { return }
        try PersistenceStore.saveModules(modules)
    }

    private func scheduleAutomaticUpdate() {
        guard !AppRuntimeOptions.isUIQAMode else { return }
        automaticUpdateTask?.cancel()
        automaticUpdateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            while self.isWorking, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            await self.updateAll()
        }
    }

    func registerLocalChange() {
        localChangeGeneration &+= 1
        cancelAutomaticPublishSchedule()
        pendingPublishPreview = nil
    }
}
