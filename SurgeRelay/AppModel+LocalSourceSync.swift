import Foundation

/// 触发本地来源同步的原因，只用于状态文案与日志语义。
enum LocalSourceSyncReason: Equatable, Sendable {
    /// App 启动后的补扫：覆盖 App 未运行期间发生的改动。
    case launch
    /// FSEvents 报告本地目录发生改动。
    case fileSystemEvent
    /// 用户手动要求立即检查本地来源。
    case manual
}

@MainActor
extension AppModel {
    /// 按当前模块与设置重建本地来源监听。监听集合没有变化时保持现有事件流。
    func refreshLocalSourceWatching() {
        guard workspaceIsActive, !isWorkspaceTransitioning, !startupRecoveryPending, !startupRecoveryFailed, !AppRuntimeOptions.isUIQAMode else { return }
        guard settings.watchesLocalModuleChanges else {
            stopLocalSourceWatching()
            return
        }
        let roots = ModuleOutputFormat.allCases.filter { settings.localStorage(for: $0).isEnabled }.map { settings.localModuleDirectory(for: $0) }
        let paths = LocalSourceSyncPlanner.watchedDirectories(modules: modules, localModuleDirectories: roots)
        guard !paths.isEmpty else {
            stopLocalSourceWatching()
            return
        }
        guard !localSourceWatcher.watches(paths) else { return }
        localSourceWatcherTask?.cancel()
        guard let events = localSourceWatcher.start(paths: paths) else { return }
        localSourceWatcherTask = Task { [weak self] in
            for await paths in events {
                guard let self, !Task.isCancelled else { return }
                self.scheduleLocalSourceSync(changedPaths: Set(paths))
            }
        }
    }

    func stopLocalSourceWatching() {
        localSourceWatcherTask?.cancel()
        localSourceWatcherTask = nil
        localSourceSyncTask?.cancel()
        localSourceSyncTask = nil
        localSourceSyncPendingDelay = nil
        localSourceSyncPendingPaths.removeAll()
        localSourceWatcher.stop()
    }

    func setWatchesLocalModuleChanges(_ enabled: Bool) {
        guard settings.watchesLocalModuleChanges != enabled else { return }
        settings.watchesLocalModuleChanges = enabled
        saveSettings()
        if enabled {
            refreshLocalSourceWatching()
            statusMessage = "已开启本地模块改动自动同步"
            Task { await syncChangedLocalSources(reason: .manual) }
        } else {
            stopLocalSourceWatching()
            statusMessage = "已关闭本地模块改动自动同步"
        }
    }

    /// 合并一段时间内的多次文件事件，只在安静下来之后同步一次。
    ///
    /// iCloud 落地和编辑器保存会产生连续事件，
    /// 直接逐事件同步会重复转换同一批模块。
    func scheduleLocalSourceSync(after delay: Duration = .milliseconds(350), changedPaths: Set<String> = []) {
        guard workspaceIsActive, !isWorkspaceTransitioning else { return }
        localSourceSyncPendingDelay = delay
        localSourceSyncPendingPaths.formUnion(changedPaths)
        guard localSourceSyncTask == nil else { return }
        localSourceSyncTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled || self.localSourceSyncTask?.isCancelled == true {
                    self.localSourceSyncTask = nil
                }
            }
            while let delay = self.localSourceSyncPendingDelay {
                self.localSourceSyncPendingDelay = nil
                do { try await Task.sleep(for: delay) } catch { return }
                guard !Task.isCancelled else { return }
                if self.localSourceSyncPendingDelay != nil { continue }
                let paths = self.localSourceSyncPendingPaths
                self.localSourceSyncPendingPaths.removeAll()
                await self.syncChangedLocalSources(reason: .fileSystemEvent, changedPaths: paths)
            }
        }
    }

    /// 同步本地来源与输出文件的磁盘改动，保留转换缓存和本地编辑。
    func syncChangedLocalSources(reason: LocalSourceSyncReason, changedPaths: Set<String>? = nil) async {
        guard workspaceIsActive, !isWorkspaceTransitioning, reason == .manual || !AppRuntimeOptions.isUIQAMode, settings.watchesLocalModuleChanges else { return }
        guard !isWorking else { return retryLocalSourceSync(reason: reason, changedPaths: changedPaths) }
        let outputChanges = await syncChangedLocalOutputs(reason: reason, changedPaths: changedPaths)
        let sourceFiles = LocalSourceSyncPlanner.sourceFiles(in: modules, includesManualOnly: reason == .manual).filter { source in
            changedPaths.map { $0.isEmpty || LocalSourceSyncPlanner.includesFile(source.url, changedPaths: $0) } ?? true
        }
        guard !sourceFiles.isEmpty else { return }
        // 正在执行其他任务时不抢占，稍后重试；否则会被 updateAdmission 直接拒绝。
        guard !isWorking else { return retryLocalSourceSync(reason: reason, changedPaths: changedPaths) }
        let hashes = await Task.detached(priority: .utility) {
            LocalSourceSyncPlanner.contentHashes(for: sourceFiles)
        }.value
        var changed = LocalSourceSyncPlanner.changedModuleIDs(
            sourceFiles: sourceFiles,
            currentHashes: hashes
        )
        var missingCount = 0
        var missingStateChanged = false
        for source in sourceFiles {
            guard let index = modules.firstIndex(where: { $0.id == source.moduleID }) else { continue }
            if !FileManager.default.fileExists(atPath: source.url.path) {
                missingCount += 1
                let message = "本地来源文件已缺失：\(source.url.path)"
                if modules[index].lastError != message {
                    modules[index].state = .failed
                    modules[index].lastError = message
                    missingStateChanged = true
                }
            } else if hashes[source.moduleID] != nil,
                      modules[index].lastError?.hasPrefix("本地来源文件已缺失：") == true {
                changed.insert(source.moduleID)
            }
        }
        if missingStateChanged {
            do { try persistModules(); try await flushPersistence() }
            catch { presentedError = "保存本地来源状态失败：\(error.localizedDescription)" }
        }
        guard !changed.isEmpty else {
            if missingCount > 0 {
                statusMessage = "\(missingCount) 个本地来源文件已缺失，缓存已保留"
            } else if reason == .manual, outputChanges.isEmpty {
                statusMessage = LocalSourceSyncPlanner.detectedStatus(
                    changedCount: 0,
                    firstModuleName: nil
                )
            }
            return
        }
        // 哈希扫描期间可能有其他任务开始执行，这里再确认一次。
        guard !isWorking else { return retryLocalSourceSync(reason: reason, changedPaths: changedPaths) }
        statusMessage = LocalSourceSyncPlanner.detectedStatus(
            changedCount: changed.count,
            firstModuleName: changed.count == 1
                ? modules.first(where: { changed.contains($0.id) })?.name
                : nil
        )
        // 本地文件改动不需要顺带检查上游 Script-Hub 引擎；引擎缺失时
        // updateAll 仍会自行补齐。
        await updateAll(only: changed, refreshesScriptHubEngine: false)
    }

    func syncChangedLocalOutputs(reason: LocalSourceSyncReason, changedPaths: Set<String>? = nil) async -> Set<UUID> {
        guard workspaceIsActive, !isWorkspaceTransitioning, !isWorking else { return [] }
        let candidates = modules.filter {
            $0.hasLocalStorageTarget && $0.hasRemoteUpdateSource && settings.localStorage(for: $0.outputFormat).isEnabled
                && (reason == .manual || $0.refreshIntervalMinutes != 0)
                && ($0.lastConvertedOutputFormat == nil || $0.lastConvertedOutputFormat == $0.outputFormat)
        }
        guard !candidates.isEmpty else { return [] }
        beginWork(.savingPreview)
        defer { endWork(.savingPreview) }
        var changed = Set<UUID>()
        var metadataChanged = false
        let generation = localChangeGeneration
        for original in candidates {
            guard shouldContinueCurrentWork(generation: generation) else { break }
            let root = settings.localModuleDirectory(for: original.outputFormat)
            guard let url = LocalSourcePathResolver.fileURL(relativePath: original.publishedRelativePath, rootDirectoryPath: root) else { continue }
            if let changedPaths, !changedPaths.isEmpty, !LocalSourceSyncPlanner.includesFile(url, changedPaths: changedPaths) { continue }
            do {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw RelayError.invalidOutput("本地模块文件已缺失：\(url.path)")
                }
                let currentContent = try? await fileStore.readComponent(id: original.id)
                if changedPaths?.isEmpty != false, currentContent != nil,
                   let cacheDate = try? await fileStore.componentModificationDate(id: original.id),
                   let fileDate = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   fileDate <= cacheDate { continue }
                let data = try await Task.detached(priority: .utility) { try SourceRevisionService.readLocalSource(url) }.value
                guard let content = String(data: data, encoding: .utf8) else { throw RelayError.invalidOutput("本地模块不是有效的 UTF-8 文本。") }
                var unchanged = currentContent == content
                if !unchanged, currentContent != nil {
                    let files = try await publishedFiles(plan: PublishPlan(standaloneModules: [original]), includeAssets: false, destination: .gitHub)
                    if let expected = files.first,
                       data == expected.data || data == ManagedPublishedFile.dataWrapping(expected.data, relativePath: original.publishedRelativePath) {
                        unchanged = true
                    }
                }
                if unchanged {
                    if let index = modules.firstIndex(where: { $0.id == original.id }),
                       modules[index].localOutputError?.hasPrefix("本地模块文件已缺失：") == true {
                        modules[index].localOutputError = nil
                        metadataChanged = true
                    }
                    continue
                }
                try await scriptHubClient.validate(content, outputFormat: original.outputFormat)
                var module = original
                module.name = ModuleMetadataParser.displayName(in: content) ?? module.name
                module.category = ModuleMetadataParser.category(in: content) ?? ""
                module.moduleDescription = ModuleMetadataParser.moduleDescription(in: content)
                module.customIconURL = ModuleMetadataParser.iconURL(in: content, relativeTo: module.updateSourceURL)?.absoluteString
                let converted = try? await fileStore.readConvertedComponent(id: module.id)
                let plan = ModulePreviewEditPlanner.savePlan(module: module, namedContent: content,
                    currentContent: currentContent, convertedContent: converted, automaticallyPublish: false)
                module = plan.module
                let defaults = ModuleArgumentProcessor.info(in: converted ?? content).definitions.reduce(into: [String: String]()) { $0[$1.key] = $1.defaultValue }
                module.argumentOverrides = ModuleArgumentProcessor.info(in: content).definitions.reduce(into: [:]) { values, definition in
                    if defaults[definition.key] != definition.defaultValue { values[definition.key] = definition.defaultValue }
                }
                let assets = try await fileStore.generatedAssetFiles(for: [module.id]).map { GeneratedAsset(relativePath: $0.name, data: $0.data) }
                let icon = await processingWorker.iconURL(in: content, relativeTo: module.updateSourceURL)
                let metadata = ModuleMetadataRefreshPlanner.plan(module: module, cachedContent: content,
                    convertedContent: converted, authoritativeSubscription: ModuleMetadataParser.scriptHubSubscription(in: content),
                    hasOverride: currentContent != nil, detectedIconURL: icon)
                module = metadata.module
                module.contentHash = await processingWorker.contentFingerprint(of: content, assets: assets)
                guard shouldContinueCurrentWork(generation: generation), modules.contains(original) else { continue }
                if currentContent == nil {
                    try await fileStore.commitConversion(ConversionResult(content: content, requestURL: url, outputFormat: module.outputFormat), id: module.id)
                } else {
                    _ = try await fileStore.recordCurrentVersion(id: module.id, reason: .beforeEdit, outputFormat: module.outputFormat)
                    try await fileStore.writeComponentOverride(content, id: module.id)
                }
                module.lastUpdatedAt = .now
                module.lastConvertedOutputFormat = module.outputFormat
                module.state = .current
                module.lastError = nil
                module.localOutputError = nil
                replace(module)
                changed.insert(module.id)
                metadataChanged = true
                recordHistory([UpdateHistoryEntry(moduleID: module.id, moduleName: module.name, outcome: .updated,
                    duration: 0, message: "已同步本地文件编辑", contentChanged: true)])
            } catch {
                guard shouldContinueCurrentWork(generation: generation), let index = modules.firstIndex(where: { $0.id == original.id }) else { continue }
                if modules[index].localOutputError != error.localizedDescription {
                    modules[index].localOutputError = error.localizedDescription
                    metadataChanged = true
                }
            }
        }
        if metadataChanged {
            do { try persistModules(); try await flushPersistence() }
            catch { presentedError = "保存本地文件同步结果失败：\(error.localizedDescription)" }
        }
        if !changed.isEmpty {
            statusMessage = "已同步 \(changed.count) 个本地模块文件的编辑"
        }
        return changed
    }

    private func retryLocalSourceSync(reason: LocalSourceSyncReason, changedPaths: Set<String>?) {
        guard reason != .manual else {
            statusMessage = updateAdmission.message
            return
        }
        scheduleLocalSourceSync(after: .seconds(5), changedPaths: changedPaths ?? [])
    }
}
