import AppKit

@MainActor
extension AppModel {
    var configurationDirectoryPath: String {
        configurationStorageDirectory.path
    }

    /// Applies the user's appearance choice to the whole app (windows + menu bar
    /// extra). `.system` clears the override so the app follows macOS again.
    func applyAppearancePreference() {
        switch settings.appearancePreference {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func setAppearancePreference(_ preference: AppearancePreference) {
        guard workspaceIsActive, !isWorkspaceTransitioning else { return }
        guard settings.appearancePreference != preference else { return }
        settings.appearancePreference = preference
        saveSettings()
        applyAppearancePreference()
    }

    func enqueueConfiguration<Value: Encodable & Sendable>(_ value: Value, fileName: String) {
        configurationWriter.enqueue(value, fileName: fileName)
        configurationWriteRevision &+= 1
        persistenceFeedbackTask?.cancel()
        persistenceFeedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            try? await self?.flushPersistence()
        }
    }

    func flushPersistence() async throws {
        let revision = configurationWriteRevision
        do {
            try await configurationWriter.flush()
            if revision == configurationWriteRevision {
                if presentedError == persistenceError { presentedError = nil }
                persistenceError = nil
            }
        } catch {
            if revision == configurationWriteRevision {
                let message = "配置尚未保存到磁盘：\(error.localizedDescription)"
                persistenceError = message
                presentedError = message
            }
            throw error
        }
    }

    func useConfigurationDirectory(_ path: String) {
        guard configurationMigrationTask == nil else { return }
        configurationMigrationTask = Task { [weak self] in
            guard let self else { return }
            defer { configurationMigrationTask = nil }
            do { try await migrateConfiguration(to: path) }
            catch { presentedError = "无法更改配置目录：\(error.localizedDescription)" }
        }
    }

    func migrateConfiguration(to path: String) async throws {
        guard !isWorking, !workActivity.isActive, workspaceIsActive else { throw PreviewContentSaveError.busy }
        let destination = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        try configurationRelocationValidation?(destination)
        beginWork(.migratingConfiguration)
        defer { endWork(.migratingConfiguration) }
        previewDraftPersistenceTask?.cancel()
        try persistModulesIfNeeded(force: true)
        enqueueConfiguration(settings, fileName: "settings.json")
        enqueueConfiguration(upstreamState, fileName: "script-hub-state.json")
        enqueueConfiguration(Array(updateHistory.prefix(200)), fileName: "update-history.json")
        if let selectedPublishAttempt { enqueueConfiguration(selectedPublishAttempt, fileName: "selected-publish.json") }
        await flushPreviewDrafts()
        if let previewDraftPersistenceError { throw RelayError.invalidOutput(previewDraftPersistenceError) }
        try await flushPersistence()
        await fileStore.versionHistoryBarrier()
        do {
            let commit = configurationRelocationCommit
            let updatesLegacySelection = isLegacyWorkspace
            configurationStorageDirectory = try await ConfigurationManager.migrateConfiguration(to: path, writer: configurationWriter) { directory in
                try commit?(directory)
                if updatesLegacySelection { PersistenceStore.selectConfigurationDirectory(directory) }
            }
            await fileStore.relocateConfigurationDirectory(to: configurationStorageDirectory)
            configurationRelocationFinished?(configurationStorageDirectory)
        } catch {
            configurationStorageDirectory = await configurationWriter.currentDirectory()
            await fileStore.relocateConfigurationDirectory(to: configurationStorageDirectory)
            configurationRelocationFinished?(configurationStorageDirectory)
            throw error
        }
        try await flushPersistence()
        statusMessage = "配置、草稿和模块历史已迁移到新的同步目录"
    }

    func setLocalModuleDirectory(_ path: String) {
        guard !isWorking else { statusMessage = PreviewContentSaveError.busy.localizedDescription; return }
        settings.localModuleDirectory = path
        localModuleOutputFolders = [ModuleOutputFolder.root]
        localModuleOutputFoldersRootPath = nil
        localModuleOutputFoldersLastRefreshedAt = nil
        saveSettings()
        refreshLocalSourceWatching()
        Task { await refreshModuleOutputFolders(force: true) }
        if settings.publishToLocal { Task { await rebuildCombinedFromCache() } }
    }

    func setPublishToLocal(_ enabled: Bool) {
        guard !isWorking else { statusMessage = PreviewContentSaveError.busy.localizedDescription; return }
        guard settings.publishToLocal != enabled else { return }
        if !enabled && !settings.publishToGitHub {
            statusMessage = "至少需要保留一个发布目标"
            return
        }
        settings.publishToLocal = enabled
        saveSettings()
        statusMessage = enabled ? "已开启本地发布" : "已关闭本地发布"
        Task { await rebuildCombinedFromCache() }
    }

    func setPublishToGitHub(_ enabled: Bool) {
        guard !isWorking else { statusMessage = PreviewContentSaveError.busy.localizedDescription; return }
        guard settings.publishToGitHub != enabled else { return }
        if !enabled && !settings.publishToLocal {
            statusMessage = "至少需要保留一个发布目标"
            return
        }
        settings.publishToGitHub = enabled
        saveSettings()
        statusMessage = enabled ? "已开启 GitHub 发布" : "已关闭 GitHub 发布"
        if enabled {
            Task { await refreshModuleOutputFolders(force: true) }
            scheduleAutomaticPublish()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard workspaceIsActive, !isWorkspaceTransitioning else { return }
        do {
            try LaunchAtLoginService.setEnabled(enabled)
            settings.launchAtLogin = enabled
            saveSettings()
        } catch {
            settings.launchAtLogin = false
            presentedError = "无法更改登录启动设置：\(error.localizedDescription)"
        }
    }

    func restartScheduler() {
        schedulerTask?.cancel()
        guard workspaceIsActive, !isWorkspaceTransitioning, !startupRecoveryPending, !startupRecoveryFailed, !AppRuntimeOptions.isUIQAMode else { return }
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let cooldowns = modules.filter { $0.serverRetryAfter.map { $0 > .now } ?? false }
                let dates = ModuleRefreshPlanner.updateableModules(in: modules, combinedModuleEnabled: settings.combinedModuleEnabled)
                    .compactMap { ModuleRefreshPlanner.nextDueDate(for: $0, among: cooldowns, globalIntervalMinutes: settings.refreshIntervalMinutes) }
                guard let next = dates.min() else { return }
                do { try await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow))) } catch { return }
                guard !Task.isCancelled else { return }
                if isWorking {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    continue
                }
                await updateAll(trigger: .scheduled)
            }
        }
    }
}
