import Foundation

@MainActor
extension AppModel {
    var configurationDirectoryPath: String {
        ConfigurationManager.configurationDirectoryPath
    }

    func useConfigurationDirectory(_ path: String) {
        do {
            try ConfigurationManager.migrateConfiguration(
                to: path,
                modules: modules,
                settings: settings,
                upstreamState: upstreamState,
                updateHistory: updateHistory
            )
            statusMessage = "配置和手动编辑内容已迁移到新的同步目录"
        } catch {
            presentedError = "无法更改配置目录：\(error.localizedDescription)"
        }
    }

    func setLocalModuleDirectory(_ path: String) {
        settings.localModuleDirectory = path
        localModuleOutputFolders = [ModuleOutputFolder.root]
        localModuleOutputFoldersRootPath = nil
        localModuleOutputFoldersLastRefreshedAt = nil
        saveSettings()
        Task { await refreshModuleOutputFolders(force: true) }
        if settings.publishToLocal { Task { await rebuildCombinedFromCache() } }
    }

    func setPublishToLocal(_ enabled: Bool) {
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
        guard let seconds = UpdateCoordinator.refreshIntervalSeconds(settings: settings) else { return }
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                await self?.updateAll()
            }
        }
    }
}
