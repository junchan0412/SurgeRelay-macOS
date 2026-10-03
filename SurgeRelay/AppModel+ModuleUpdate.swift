import Foundation

@MainActor
extension AppModel {
    func updateSingleModule(_ moduleValue: RelayModule, generation updateGeneration: Int) async -> ModuleUpdateOutcome? {
        let metrics = StageMetricsRecorder()
        return await StageMetricsContext.$current.withValue(metrics) {
            await updateMeasuredModule(moduleValue, generation: updateGeneration, metrics: metrics)
        }
    }

    private func updateMeasuredModule(_ moduleValue: RelayModule, generation updateGeneration: Int, metrics: StageMetricsRecorder) async -> ModuleUpdateOutcome? {
        let measuredStart = ContinuousClock.now
        defer { setWorkStage(nil, moduleID: moduleValue.id, moduleName: moduleValue.name) }
        var components: [(RelayModule, String)] = []
        var failures = 0
        var missingCache: [String] = []
        var missingCacheDetails: [String] = []
        var contentChanged = false
        var newHistory: [UpdateHistoryEntry] = []
        func outcome() -> ModuleUpdateOutcome {
            ModuleUpdateOutcome(components: components, failures: failures, missingCache: missingCache,
                                missingCacheDetails: missingCacheDetails, contentChanged: contentChanged, history: newHistory.map {
                                    var entry = $0
                                    entry.duration = StageMetricsRecorder.elapsed(since: measuredStart)
                                    entry.stageMetrics = metrics.snapshot
                                    return entry
                                })
        }
        guard shouldContinueCurrentWork(generation: updateGeneration) else { return nil }
        var module = moduleValue
        let startedAt = Date.now
        if let server = ModuleRefreshPlanner.serverDeadline(for: module, among: modules), server > startedAt { return nil }
        module.lastRefreshAttemptAt = startedAt
        if let index = modules.firstIndex(where: { $0.id == module.id }) { modules[index].lastRefreshAttemptAt = startedAt }
        var revisionSnapshot: SourceRevisionSnapshot?
        var sourceCheckFailure: (any Error)?
        synchronizingModuleIDs.insert(module.id)
        defer { synchronizingModuleIDs.remove(module.id) }
        setState(id: module.id, state: .updating, error: nil)
        // Avoid rewriting identical high-frequency status strings for every module
        // when the UI already shows per-module progress.
        if synchronizationTotalCount <= 1 {
            statusMessage = "正在检查 \(module.name)…"
        } else if synchronizationCompletedCount == 0 {
            statusMessage = "正在更新 \(synchronizationTotalCount) 个模块…"
        }
        do {
            setWorkStage(.cache, moduleID: module.id, moduleName: module.name)
            let hasCache = await metrics.measure(.cache, reason: "检查缓存") { await fileStore.hasComponent(id: module.id) }
            if let conflict = try await moduleSyncConflict(for: &module) {
                guard shouldContinueCurrentWork(generation: updateGeneration) else { return nil }
                module.syncConflict = conflict
                module.state = .failed
                module.lastError = "\(conflict.comparisonState.title)，请比较后选择覆盖方向。"
                ModuleRefreshPlanner.recordFailure(&module)
                replace(module)
                failures += 1
                newHistory.append(UpdateHistoryEntry(
                    moduleID: module.id,
                    moduleName: module.name,
                    outcome: .failed,
                    duration: Date.now.timeIntervalSince(startedAt),
                    message: "本地与 GitHub 输出冲突，已暂停更新"
                ))
                return outcome()
            }
            let sourceURL = URL(string: module.updateSourceURL)
            let nativeModule = sourceURL.map { module.sourceFormat.isNativeSurgeModule(for: $0) } ?? false
            let engineChanged = !nativeModule && module.conversionEngineRevision != upstreamState.revision
            if hasCache || nativeModule {
                do {
                    setWorkStage(sourceURL?.isFileURL == true ? .cache : .download, moduleID: module.id, moduleName: module.name)
                    let revision = try await sourceRevisionService.check(module, hasCache: hasCache)
                    switch revision {
                    case let .unchanged(snapshot):
                        revisionSnapshot = snapshot
                        if !engineChanged {
                            setWorkStage(.cache, moduleID: module.id, moduleName: module.name)
                            let cached = try await metrics.measure(.cache, reason: snapshot.data == nil ? "HTTP 304，沿用缓存" : "来源内容未变，沿用缓存", bytes: { (Int64($0.utf8.count), nil) }) {
                                try await fileStore.readComponent(id: module.id)
                            }
                            let materialized = shouldContributeToCombined(module)
                                ? await metrics.measure(.conversion, reason: "缓存参数展开") { await processingWorker.materialize(cached, overrides: module.argumentOverrides) } : nil
                            guard shouldContinueCurrentWork(generation: updateGeneration) else { return nil }
                            let metadataPlan = ModuleMetadataRefreshPlanner.unchangedCachedContentPlan(
                                module: module,
                                revisionSnapshot: snapshot
                            )
                            module = metadataPlan.module
                            ModuleRefreshPlanner.clearFailureState(&module)
                            replace(module)
                            if let materialized {
                                components.append((module, materialized))
                            }
                            newHistory.append(UpdateHistoryEntry(
                                moduleID: module.id,
                                moduleName: module.name,
                                outcome: .unchanged,
                                duration: Date.now.timeIntervalSince(startedAt),
                                message: metadataPlan.historyMessage
                            ))
                            return outcome()
                        }
                    case let .changed(snapshot):
                        revisionSnapshot = snapshot
                    }
                } catch {
                    if error is SourceRetryAfterError { throw error }
                    if case let RelayError.httpFailure(status, _) = error, status == 429 { throw error }
                    sourceCheckFailure = error
                    // A failed lightweight check must not prevent the normal conversion path.
                }
            }
            guard shouldContinueCurrentWork(generation: updateGeneration) else { return nil }
            if synchronizationTotalCount <= 1 {
                statusMessage = "正在内置转换 \(module.name)…"
            }
            if let server = ModuleRefreshPlanner.serverDeadline(for: module, among: modules), server > .now { return nil }
            setWorkStage(.conversion, moduleID: module.id, moduleName: module.name, detail: nativeModule ? "原生模块处理" : "转换 / 获取引用内容")
            let result = try await convertModuleWithTransientRetry(
                module: module,
                hasCache: hasCache,
                updateGeneration: updateGeneration,
                sourceData: nativeModule ? revisionSnapshot?.data : nil
            )
            guard shouldContinueCurrentWork(generation: updateGeneration) else { return nil }
            guard let currentIndex = modules.firstIndex(where: { $0.id == module.id }),
                  shouldUpdateModule(modules[currentIndex]) else {
                statusMessage = "检测到新的修改，已放弃旧更新"
                return nil
            }
            setWorkStage(.cache, moduleID: module.id, moduleName: module.name)
            let prepared = try await metrics.measure(.cache, reason: "准备有效缓存") {
                try await fileStore.prepareConversion(result, id: module.id)
            }
            let effectiveContent = prepared.effective
            guard shouldContinueCurrentWork(generation: updateGeneration) else { return nil }
            guard let latestIndex = modules.firstIndex(where: { $0.id == module.id }),
                  shouldUpdateModule(modules[latestIndex]) else {
                statusMessage = "检测到新的修改，已放弃旧更新"
                return nil
            }
            module = modules[latestIndex]
            let convertedContent = prepared.converted
            let detectedIcon = await metrics.measure(.conversion, reason: "元数据整理") {
                await processingWorker.iconURL(in: effectiveContent, relativeTo: module.updateSourceURL)
            }
            let nextContentHash = await metrics.measure(.conversion, reason: "内容校验") {
                await processingWorker.contentFingerprint(of: effectiveContent, assets: result.assets)
            }
            guard shouldContinueCurrentWork(generation: updateGeneration) else { return nil }
            let metadataPlan = ModuleMetadataRefreshPlanner.successfulConversionPlan(
                module: module,
                revisionSnapshot: revisionSnapshot,
                nativeModule: nativeModule,
                engineRevision: upstreamState.revision,
                convertedContent: convertedContent,
                effectiveContent: effectiveContent,
                hasOverride: prepared.hasOverride,
                detectedIconURL: detectedIcon,
                nextContentHash: nextContentHash
            )
            let cacheBytes = Int64(result.content.utf8.count + result.assets.reduce(0) { $0 + $1.data.count })
            try await metrics.measure(.cache, reason: prepared.hasOverride ? "提交缓存，保留手动覆盖" : "提交缓存", bytes: { _ in (nil, cacheBytes) }) {
                try await fileStore.commitConversion(result, id: module.id)
            }
            guard shouldContinueCurrentWork(generation: updateGeneration) else { return nil }
            module = metadataPlan.module
            ModuleRefreshPlanner.clearFailureState(&module)
            if metadataPlan.contentChanged { contentChanged = true }
            if let preferredIcon = metadataPlan.preferredIconURL {
                try? await iconStore.cacheIcon(
                    from: preferredIcon,
                    for: module.id,
                    force: metadataPlan.shouldRefreshIconCache
                )
            } else {
                try? await iconStore.removeIcon(for: module.id)
            }
            guard localChangeGeneration == updateGeneration else { return nil }
            replace(module)
            newHistory.append(UpdateHistoryEntry(
                moduleID: module.id,
                moduleName: module.name,
                outcome: .updated,
                duration: Date.now.timeIntervalSince(startedAt),
                message: metadataPlan.historyMessage,
                contentChanged: metadataPlan.contentChanged
            ))
            if shouldContributeToCombined(module) {
                let materialized = await metrics.measure(.conversion, reason: "展开汇总参数") {
                    await processingWorker.materialize(effectiveContent, overrides: module.argumentOverrides)
                }
                components.append((module, materialized))
            }
        } catch {
            guard shouldContinueCurrentWork(generation: updateGeneration) else { return nil }
            failures += 1
            let sourceFailure = await sourceCheckFailureAfterConversionFailure(
                error,
                module: module,
                existingFailure: sourceCheckFailure
            )
            guard shouldContinueCurrentWork(generation: updateGeneration) else { return nil }
            let failureMessage = UpdateFailurePlanner.detailedMessage(
                for: error,
                module: module,
                latestModule: modules.first(where: { $0.id == module.id }),
                sourceCheckFailure: sourceFailure
            )
            if let index = modules.firstIndex(where: { $0.id == module.id }) {
                var failed = modules[index]
                let retryFailure: (any Error)? = (error as? SourceRetryAfterError) ?? (sourceFailure as? SourceRetryAfterError)
                ModuleRefreshPlanner.recordFailure(&failed, error: retryFailure ?? error)
                failed.state = .failed
                failed.lastError = failureMessage
                modules[index] = failed
                module = failed
            }
            setWorkStage(.cache, moduleID: module.id, moduleName: module.name, detail: "检查可用回退")
            if let cached = try? await metrics.measure(.cache, reason: sourceFailure == nil ? "转换失败，检查回退缓存" : "来源失败，检查回退缓存", bytes: { (Int64($0.utf8.count), nil) }, operation: {
                try await fileStore.readComponent(id: module.id)
            }) {
                let current = modules.first(where: { $0.id == module.id }) ?? module
                let materialized = await processingWorker.materialize(
                    cached,
                    overrides: current.argumentOverrides
                )
                let failurePlan = UpdateFailurePlanner.cachedFailureOutcome(
                    module: module,
                    failureMessage: failureMessage,
                    duration: Date.now.timeIntervalSince(startedAt),
                    contributesToCombined: shouldContributeToCombined(current)
                )
                if failurePlan.shouldUseCachedContentInCombined {
                    components.append((current, materialized))
                }
                newHistory.append(failurePlan.historyEntry)
            } else {
                metrics.record(StageMetric(stage: .cache, duration: 0, attempts: 0, result: .failed, reason: "没有可用缓存，无法回退"))
                let failurePlan = UpdateFailurePlanner.missingCacheFailureOutcome(
                    module: module,
                    failureMessage: failureMessage,
                    duration: Date.now.timeIntervalSince(startedAt),
                    contributesToCombined: shouldContributeToCombined(module)
                )
                if let moduleName = failurePlan.missingCacheModuleName {
                    missingCache.append(moduleName)
                }
                if let detail = failurePlan.missingCacheDetail {
                    missingCacheDetails.append(detail)
                }
                newHistory.append(failurePlan.historyEntry)
            }
        }
        return outcome()
    }

    private func moduleSyncScope(for module: RelayModule) -> String {
        let root = URL(filePath: settings.localModuleDirectory, directoryHint: .isDirectory).standardizedFileURL.path
        return Data([root, PublishCoordinator.repositoryKey(settings.github), module.publishedRelativePath].joined(separator: "\n").utf8).sha256String
    }

    private func moduleSyncConflict(for module: inout RelayModule) async throws -> ModuleSyncConflictMetadata? {
        guard module.publishesStandalone, module.hasLocalStorageTarget, module.hasGitHubStorageTarget,
              settings.publishToGitHub, settings.github.isConfigured, !githubToken.isEmpty else { return nil }
        guard let snapshot = try await readModuleSyncComparison(for: module, includesDiff: false, allowsMissing: true) else { return nil }
        if snapshot.metadata.comparisonState == .same {
            module.syncBaseHash = snapshot.metadata.localHash
            module.syncBaseScope = snapshot.scope
            module.syncConflict = nil
            return nil
        }
        return snapshot.metadata
    }

    func recordModuleSyncBaselines(moduleIDs: Set<UUID>) async {
        for id in moduleIDs {
            guard let module = modules.first(where: { $0.id == id }),
                  module.hasLocalStorageTarget, module.hasGitHubStorageTarget,
                  let snapshot = try? await readModuleSyncComparison(for: module, includesDiff: false, allowsMissing: true),
                  snapshot.metadata.comparisonState == .same,
                  let index = modules.firstIndex(where: { $0.id == id }),
                  moduleSyncScope(for: modules[index]) == snapshot.scope else { continue }
            modules[index].syncBaseHash = snapshot.metadata.localHash
            modules[index].syncBaseScope = snapshot.scope
            if modules[index].syncConflict != nil {
                modules[index].syncConflict = nil
                modules[index].lastError = nil
                modules[index].state = .current
            }
        }
        persistModulesIfNeededIgnoringErrors(force: true)
        try? await flushPersistence()
    }

    func moduleSyncComparison(moduleID: UUID) async throws -> ModuleSyncComparison {
        guard !isWorking else { throw RelayError.invalidOutput("当前有任务正在执行，请稍后再比较。") }
        guard let module = modules.first(where: { $0.id == moduleID }) else { throw RelayError.invalidOutput("模块已移除。") }
        beginWork(.previewingPublish)
        defer { endWork(.previewingPublish) }
        guard let comparison = try await readModuleSyncComparison(for: module, includesDiff: true) else {
            throw RelayError.invalidOutput("找不到可比较的两端发布文件。")
        }
        try checkCurrentWorkCancellation()
        return comparison
    }

    private func readModuleSyncComparison(
        for module: RelayModule,
        includesDiff: Bool,
        allowsMissing: Bool = false
    ) async throws -> ModuleSyncComparison? {
        guard module.publishesStandalone, module.hasLocalStorageTarget, module.hasGitHubStorageTarget,
              settings.publishToLocal, settings.publishToGitHub, settings.github.isConfigured, !githubToken.isEmpty else {
            if allowsMissing { return nil }
            throw RelayError.invalidOutput("请先开启并配置模块的本地与 GitHub 双目标。")
        }
        let scope = moduleSyncScope(for: module)
        let path = module.publishedRelativePath
        let localRoot = settings.localModuleDirectory
        let githubSettings = settings.github
        let token = githubToken
        guard let local = try await fileStore.readPublishedFile(relativePath: path, rootDirectoryPath: localRoot),
              let remote = try await githubClient.fileSnapshot(fileName: path, settings: githubSettings, token: token) else {
            if allowsMissing { return nil }
            throw RelayError.invalidOutput("找不到本地或 GitHub 发布文件，请先检查发布结果。")
        }
        guard let current = modules.first(where: { $0.id == module.id }), moduleSyncScope(for: current) == scope else {
            throw RelayError.invalidOutput("模块发布位置已变化，请重新比较。")
        }
        let localURL = URL(filePath: localRoot, directoryHint: .isDirectory).appending(path: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let localData = ModuleSyncPlanner.normalizedPublishedData(local)
        let githubData = ModuleSyncPlanner.normalizedPublishedData(remote.data)
        let metadata = ModuleSyncConflictMetadata(
            localHash: localData.sha256String,
            githubHash: githubData.sha256String,
            localUpdatedAt: attributes[.modificationDate] as? Date ?? .now,
            githubUpdatedAt: remote.updatedAt,
            detectedAt: .now,
            baseHash: module.syncBaseScope == scope ? module.syncBaseHash : nil,
            githubCommitSHA: remote.commitSHA
        )
        var diff = ModuleLineDiff(rows: [], removedCount: 0, addedCount: 0, isTruncated: false, usesCoarseComparison: false)
        if includesDiff {
            guard let localText = String(data: localData, encoding: .utf8), let githubText = String(data: githubData, encoding: .utf8) else {
                throw RelayError.invalidOutput("发布文件不是有效的 UTF-8 文本，无法比较。")
            }
            let worker = Task.detached(priority: .userInitiated) { ModuleLineDiffPlanner.compare(local: localText, github: githubText) }
            diff = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
        }
        return ModuleSyncComparison(moduleID: module.id, scope: scope, localData: localData, githubData: githubData,
                                    localFileHash: local.sha256String, githubCommitSHA: remote.commitSHA, metadata: metadata, diff: diff)
    }

    func resolveModuleSyncConflict(
        moduleID: UUID,
        resolution: ModuleSyncResolution,
        comparison: ModuleSyncComparison
    ) async -> Bool {
        guard !isWorking else { presentedError = "当前有任务正在执行，请稍后再解决差异。"; return false }
        guard let module = modules.first(where: { $0.id == moduleID }), comparison.moduleID == moduleID else { return false }
        beginWork(.confirmingPublish)
        defer { endWork(.confirmingPublish) }
        var mutationStarted = false
        do {
            guard let current = try await readModuleSyncComparison(for: module, includesDiff: false),
                  ModuleSyncPlanner.isCurrent(comparison, comparedTo: current) else {
                throw RelayError.invalidOutput("文件或发布位置在比较后发生变化，请重新比较后确认。")
            }
            try checkCurrentWorkCancellation()
            let winner = resolution == .localWins ? current.localData : current.githubData
            guard let winnerText = String(data: winner, encoding: .utf8) else { throw RelayError.invalidOutput("胜出版本不是有效的 UTF-8 文本。") }
            let converted = try? await modulePreviewProvider.convertedComponentContent(for: module)
            try enterNonCancellableWorkPhase(statusMessage: "正在按确认方向同步发布文件…")
            mutationStarted = true
            switch resolution {
            case .localWins:
                let report = try await githubClient.publish(
                    files: [PublishFile(name: module.publishedRelativePath, data: winner)],
                    settings: settings.github, token: githubToken, expectedHeadCommitSHA: current.githubCommitSHA
                )
                recordGitHubPublish(report)
            case .githubWins:
                _ = try await fileStore.exportPublishedFiles(
                    [PublishFile(name: module.publishedRelativePath, data: winner)],
                    toRootDirectory: settings.localModuleDirectory,
                    knownManagedRelativePaths: settings.localPublishedFilePaths,
                    expectedExistingHashes: [module.publishedRelativePath: current.localFileHash]
                )
            }
            guard let verified = try await readModuleSyncComparison(for: module, includesDiff: false),
                  verified.metadata.localHash == winner.sha256String,
                  verified.metadata.githubHash == winner.sha256String else {
                throw RelayError.invalidOutput("已执行覆盖，但两端在校验时再次变化；未记录共同基线，请重新比较。")
            }
            try await fileStore.writeComponentOverride(winnerText, id: moduleID)
            guard var updated = modules.first(where: { $0.id == moduleID }) else { return false }
            updated.overrideBaseHash = converted.map { Data($0.utf8).sha256String }
            updated.hasOverrideConflict = false
            updated.contentHash = Data(try await fileStore.readComponent(id: moduleID).utf8).sha256String
            updated.syncBaseHash = winner.sha256String
            updated.syncBaseScope = verified.scope
            updated.syncConflict = nil
            updated.lastError = nil
            updated.state = .current
            replace(updated)
            try persistModules()
            try await flushPersistence()
            let refreshed = await rebuildCombinedFromCache(schedulesAutomaticPublish: false, exportsLocalOutput: false)
            guard refreshed else {
                statusMessage = "两端同步已完成，但总模块缓存刷新失败，请检查错误后重新合并"
                return false
            }
            statusMessage = resolution == .localWins ? "已用本地版本覆盖 GitHub，并记录共同基线" : "已用 GitHub 版本覆盖本地，并记录共同基线"
            return true
        } catch {
            presentedError = mutationStarted
                ? "同步未获完整确认，发布文件可能已变化；请重新比较。\(error.localizedDescription)"
                : error.localizedDescription
            return false
        }
    }

    /// 对新模块（尚无缓存内容）的转换做一次瞬态失败重试，避免首次自动更新因
    /// 瞬时 404 / 5xx / 网络抖动失败后留下空内容，需要用户手动再点一次更新。
    private func convertModuleWithTransientRetry(
        module: RelayModule,
        hasCache: Bool,
        updateGeneration: Int,
        sourceData: Data?
    ) async throws -> ConversionResult {
        let github = settings.github.isConfigured ? settings.github : nil
        do {
            return try await scriptHubClient.convert(module: module, github: github, sourceData: sourceData)
        } catch {
            guard !hasCache,
                  !(error is SourceRetryAfterError),
                  UpdateRetryPolicy.shouldRetryTransientFailure(error),
                  !Task.isCancelled,
                  !workCancellationRequested else {
                throw error
            }
            try await Task.sleep(for: .milliseconds(1500))
            guard shouldContinueCurrentWork(generation: updateGeneration) else {
                throw CancellationError()
            }
            return try await scriptHubClient.convert(module: module, github: github, sourceData: sourceData)
        }
    }

    private func sourceCheckFailureAfterConversionFailure(
        _ error: any Error,
        module: RelayModule,
        existingFailure: (any Error)?
    ) async -> (any Error)? {
        if error is SourceRetryAfterError { return error }
        if let existingFailure { return existingFailure }
        guard UpdateFailurePlanner.shouldCheckUpdateSourceAfterConversionFailure(
            error,
            module: module,
            existingSourceCheckFailure: existingFailure
        ) else {
            return nil
        }

        do {
            _ = try await sourceRevisionService.check(module)
            return nil
        } catch {
            return error
        }
    }
}
