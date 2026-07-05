import Foundation

@MainActor
extension AppModel {
    func updateAll() async {
        let admission = updateAdmission
        guard admission.isAccepted else {
            statusMessage = admission.message
            return
        }
        let updateModules = ModuleRefreshPlanner.updateableModules(
            in: modules,
            combinedModuleEnabled: settings.combinedModuleEnabled
        )
        cancelAutomaticPublishSchedule()
        let updateGeneration = localChangeGeneration
        beginWork(.updatingModules)
        synchronizationCompletedCount = 0
        synchronizationTotalCount = updateModules.count
        synchronizingModuleID = nil
        defer {
            synchronizingModuleID = nil
            endWork(.updatingModules)
        }

        let missingEngine = !(await engineStore.hasScript(named: "Rewrite-Parser.js"))
        if settings.automaticallyUpdateScriptHub || missingEngine {
            await refreshScriptHubInternal()
        }
        guard shouldContinueCurrentWork(generation: updateGeneration) else { return }

        if settings.github.repositoryIsPrivate == nil,
           settings.github.isConfigured,
           githubTokenStorageStatus != .notChecked,
           !githubToken.isEmpty,
           let isPrivate = try? await githubClient.test(settings: settings.github, token: githubToken) {
            settings.github.repositoryIsPrivate = isPrivate
            saveSettings()
        }
        guard shouldContinueCurrentWork(generation: updateGeneration) else { return }

        var components: [(RelayModule, String)] = []
        var failures = 0
        var missingCache: [String] = []
        var missingCacheDetails: [String] = []
        var contentChanged = false
        var newHistory: [UpdateHistoryEntry] = []

        for moduleValue in updateModules {
            guard shouldContinueCurrentWork(generation: updateGeneration) else { return }
            var module = moduleValue
            let startedAt = Date.now
            var revisionSnapshot: SourceRevisionSnapshot?
            var sourceCheckFailure: (any Error)?
            synchronizingModuleID = module.id
            setState(id: module.id, state: .updating, error: nil)
            statusMessage = "正在检查 \(module.name)…"
            do {
                let hasCache = await fileStore.hasComponent(id: module.id)
                let sourceURL = URL(string: module.sourceURL)
                let nativeModule = sourceURL.map { module.sourceFormat.isNativeSurgeModule(for: $0) } ?? false
                let engineChanged = !nativeModule && module.conversionEngineRevision != upstreamState.revision
                if hasCache {
                    do {
                        let revision = try await sourceRevisionService.check(module)
                        switch revision {
                        case let .unchanged(snapshot):
                            revisionSnapshot = snapshot
                            if !engineChanged {
                                let metadataPlan = ModuleMetadataRefreshPlanner.unchangedCachedContentPlan(
                                    module: module,
                                    revisionSnapshot: snapshot
                                )
                                module = metadataPlan.module
                                replace(module)
                                let cached = try await fileStore.readComponent(id: module.id)
                                let materialized = await processingWorker.materialize(cached, overrides: module.argumentOverrides)
                                if shouldContributeToCombined(module) {
                                    components.append((module, materialized))
                                }
                                newHistory.append(UpdateHistoryEntry(
                                    moduleID: module.id,
                                    moduleName: module.name,
                                    outcome: .unchanged,
                                    duration: Date.now.timeIntervalSince(startedAt),
                                    message: metadataPlan.historyMessage
                                ))
                                synchronizationCompletedCount += 1
                                await Task.yield()
                                continue
                            }
                        case let .changed(snapshot):
                            revisionSnapshot = snapshot
                        }
                    } catch {
                        sourceCheckFailure = error
                        // A failed lightweight check must not prevent the normal conversion path.
                    }
                }
                guard shouldContinueCurrentWork(generation: updateGeneration) else { return }
                statusMessage = "正在内置转换 \(module.name)…"
                let result = try await scriptHubClient.convert(
                    module: module,
                    github: settings.github.isConfigured ? settings.github : nil
                )
                guard shouldContinueCurrentWork(generation: updateGeneration) else { return }
                guard let currentIndex = modules.firstIndex(where: { $0.id == module.id }),
                      shouldUpdateModule(modules[currentIndex]) else {
                    statusMessage = "检测到新的修改，已放弃旧更新"
                    return
                }
                try await fileStore.replaceAssets(result.assets, id: module.id)
                try await fileStore.writeComponent(result.content, id: module.id)
                let effectiveContent = try await fileStore.readComponent(id: module.id)
                guard shouldContinueCurrentWork(generation: updateGeneration) else { return }
                guard let latestIndex = modules.firstIndex(where: { $0.id == module.id }),
                      shouldUpdateModule(modules[latestIndex]) else {
                    statusMessage = "检测到新的修改，已放弃旧更新"
                    return
                }
                module = modules[latestIndex]
                let convertedContent = try await fileStore.readConvertedComponent(id: module.id)
                let detectedIcon = await processingWorker.iconURL(
                    in: effectiveContent,
                    relativeTo: module.sourceURL
                )
                let nextContentHash = await processingWorker.contentFingerprint(
                    of: effectiveContent,
                    assets: result.assets
                )
                let metadataPlan = await ModuleMetadataRefreshPlanner.successfulConversionPlan(
                    module: module,
                    revisionSnapshot: revisionSnapshot,
                    nativeModule: nativeModule,
                    engineRevision: upstreamState.revision,
                    convertedContent: convertedContent,
                    effectiveContent: effectiveContent,
                    hasOverride: fileStore.hasOverride(id: module.id),
                    detectedIconURL: detectedIcon,
                    nextContentHash: nextContentHash
                )
                module = metadataPlan.module
                if let preferredIcon = metadataPlan.preferredIconURL {
                    try? await iconStore.cacheIcon(
                        from: preferredIcon,
                        for: module.id,
                        force: metadataPlan.shouldRefreshIconCache
                    )
                } else {
                    try? await iconStore.removeIcon(for: module.id)
                }
                if metadataPlan.contentChanged { contentChanged = true }
                replace(module)
                newHistory.append(UpdateHistoryEntry(
                    moduleID: module.id,
                    moduleName: module.name,
                    outcome: .updated,
                    duration: Date.now.timeIntervalSince(startedAt),
                    message: metadataPlan.historyMessage,
                    contentChanged: metadataPlan.contentChanged
                ))
                let materialized = await processingWorker.materialize(
                    effectiveContent,
                    overrides: module.argumentOverrides
                )
                if shouldContributeToCombined(module) {
                    components.append((module, materialized))
                }
            } catch {
                guard shouldContinueCurrentWork(generation: updateGeneration) else { return }
                failures += 1
                let sourceFailure = await sourceCheckFailureAfterConversionFailure(
                    error,
                    module: module,
                    existingFailure: sourceCheckFailure
                )
                let failureMessage = UpdateFailurePlanner.detailedMessage(
                    for: error,
                    module: module,
                    latestModule: modules.first(where: { $0.id == module.id }),
                    sourceCheckFailure: sourceFailure
                )
                setState(id: module.id, state: .failed, error: failureMessage)
                if let cached = try? await fileStore.readComponent(id: module.id) {
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
            synchronizationCompletedCount += 1
            await Task.yield()
        }
        recordHistory(newHistory)
        try? persistModules()

        guard shouldContinueCurrentWork(generation: updateGeneration) else { return }

        if let blockage = UpdateFailurePlanner.missingCacheBlockage(
            moduleNames: missingCache,
            details: missingCacheDetails
        ) {
            statusMessage = blockage.statusMessage
            presentedError = blockage.presentedError
            return
        }

        do {
            if settings.combinedModuleEnabled {
                try await writeCombinedModule(components)
            } else {
                try? await fileStore.removeCombined()
                try await publishCurrentFiles(combinedData: nil, includeAssets: false)
            }
            guard shouldContinueCurrentWork(generation: updateGeneration) else { return }
            await cleanupLegacyOutputFiles()
            guard shouldContinueCurrentWork(generation: updateGeneration) else { return }
            let canUseAutomaticGitHubPublish = AutomaticPublishPlanner.canUseAutomaticPublishing(
                context: automaticPublishContext()
            )
            let pendingLocalCleanupFileCount = pendingPublishPreview?.destination == .local
                ? pendingPublishPreview?.deletedFiles.count
                : nil
            let completionDecision = UpdateCompletionStatusPlanner.decision(
                canUseAutomaticGitHubPublish: canUseAutomaticGitHubPublish,
                publishPlan: githubPublishPlan,
                contentChanged: contentChanged,
                failures: failures,
                pendingLocalCleanupFileCount: pendingLocalCleanupFileCount,
                combinedModuleEnabled: settings.combinedModuleEnabled,
                combinedSourceCount: components.count
            )
            switch completionDecision.scheduleAction {
            case .none:
                break
            case .scheduleAutomaticPublish:
                scheduleAutomaticPublish()
            case .clearAutomaticPublishSchedule:
                clearAutomaticPublishSchedule()
            }
            statusMessage = completionDecision.statusMessage
        } catch {
            if isCurrentWorkCancellation(error) { return }
            presentedError = settings.combinedModuleEnabled
                ? "合并失败，当前总模块未被覆盖：\(error.localizedDescription)"
                : "刷新模块输出失败：\(error.localizedDescription)"
        }
    }

    func update(moduleID: UUID) async {
        // 单个来源改变可能影响总模块，也可能触发独立模块输出，因此统一走批量更新路径。
        guard let module = modules.first(where: { $0.id == moduleID }) else { return }
        let admission = updateAdmission(for: module)
        guard admission.isAccepted else {
            statusMessage = admission.message
            return
        }
        await updateAll()
    }

    func refreshScriptHub(showProgress: Bool = true) async {
        guard !isWorking || !showProgress else { return }
        if showProgress { beginWork(.refreshingScriptHub) }
        await refreshScriptHubInternal()
        if showProgress {
            guard shouldContinueCurrentWork() else {
                endWork(.refreshingScriptHub)
                return
            }
        }
        if showProgress { endWork(.refreshingScriptHub) }
    }

    private func refreshScriptHubInternal() async {
        statusMessage = "正在更新 App 内置 Script-Hub 引擎…"
        do {
            let result = try await upstreamService.fetchManagedModule(
                from: settings.scriptHubModuleURL,
                previousRevision: upstreamState.revision,
                previousUpstreamRevision: upstreamState.upstreamRevision,
                previousScriptHashes: upstreamState.scriptHashes
            )
            let missing = !(await engineStore.hasScript(named: "Rewrite-Parser.js"))
            if result.changed || missing {
                try await engineStore.save(scripts: result.scripts)
                upstreamState.lastUpdatedAt = .now
            }
            upstreamState.revision = result.revision
            upstreamState.sourceDescription = result.sourceDescription
            upstreamState.upstreamRevision = result.upstreamRevision
            upstreamState.scriptHashes = result.scriptHashes
            upstreamState.lastCheckedAt = .now
            upstreamState.lastError = nil
            PersistenceStore.saveUpstreamState(upstreamState)
            statusMessage = result.changed ? "内置 Script-Hub 引擎已更新至 \(result.revision)" : "内置 Script-Hub 引擎已是最新"
        } catch {
            upstreamState.lastCheckedAt = .now
            upstreamState.lastError = error.localizedDescription
            PersistenceStore.saveUpstreamState(upstreamState)
            let hasCache = await engineStore.hasScript(named: "Rewrite-Parser.js")
            statusMessage = hasCache ? "上游检查失败，继续使用 App 内缓存引擎" : "内置转换引擎尚不可用"
        }
    }

    func testGitHub(showProgress: Bool = true) async {
        guard !isWorking || !showProgress else { return }
        if showProgress { beginWork(.testingGitHub) }
        defer { if showProgress { endWork(.testingGitHub) } }
        do {
            let token = ensureGitHubTokenLoaded(showStatusMessage: showProgress)
            guard !token.isEmpty else { throw RelayError.githubTokenMissing }
            let isPrivate = try await githubClient.test(settings: settings.github, token: token)
            if showProgress {
                guard shouldContinueCurrentWork() else { return }
            }
            settings.github.repositoryIsPrivate = isPrivate
            saveSettings()
            await refreshModuleOutputFolders(force: true)
            statusMessage = isPrivate ? "GitHub 私有仓库连接成功，需要配置 Cloudflare Worker" : "GitHub 公开仓库连接成功，将直接使用 Raw 地址"
        } catch {
            if showProgress, isCurrentWorkCancellation(error) { return }
            presentedError = error.localizedDescription
        }
    }

    private func sourceCheckFailureAfterConversionFailure(
        _ error: any Error,
        module: RelayModule,
        existingFailure: (any Error)?
    ) async -> (any Error)? {
        if let existingFailure { return existingFailure }
        guard UpdateFailurePlanner.shouldCheckOriginalSourceAfterConversionFailure(
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
