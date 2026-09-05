import Foundation

/// 触发本地来源同步的原因，只用于状态文案与日志语义。
enum LocalSourceSyncReason: Sendable {
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
        guard !AppRuntimeOptions.isUIQAMode else { return }
        guard settings.watchesLocalModuleChanges else {
            stopLocalSourceWatching()
            return
        }
        let paths = LocalSourceSyncPlanner.watchedDirectories(
            modules: modules,
            localModuleDirectory: settings.localModuleDirectory
        )
        guard !paths.isEmpty else {
            stopLocalSourceWatching()
            return
        }
        guard !localSourceWatcher.watches(paths) else { return }
        localSourceWatcherTask?.cancel()
        guard let events = localSourceWatcher.start(paths: paths) else { return }
        localSourceWatcherTask = Task { [weak self] in
            for await _ in events {
                guard let self, !Task.isCancelled else { return }
                self.scheduleLocalSourceSync()
            }
        }
    }

    func stopLocalSourceWatching() {
        localSourceWatcherTask?.cancel()
        localSourceWatcherTask = nil
        localSourceSyncTask?.cancel()
        localSourceSyncTask = nil
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
    /// iCloud 落地、编辑器保存和 Surge Relay 自己的发布写入都会产生连续事件，
    /// 直接逐事件同步会重复转换同一批模块。
    func scheduleLocalSourceSync(after delay: Duration = .milliseconds(900)) {
        localSourceSyncTask?.cancel()
        localSourceSyncTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.syncChangedLocalSources(reason: .fileSystemEvent)
        }
    }

    /// 比较本地来源文件的当前内容哈希，只更新真正改动过的模块。
    ///
    /// 判据与 `SourceRevisionService` 一致，因此重复调用是幂等的：转换成功后
    /// `sourceContentHash` 会写回磁盘内容的哈希，下一轮扫描不再认为有改动。
    func syncChangedLocalSources(reason: LocalSourceSyncReason) async {
        guard !AppRuntimeOptions.isUIQAMode, settings.watchesLocalModuleChanges else { return }
        let sourceFiles = LocalSourceSyncPlanner.sourceFiles(in: modules)
        guard !sourceFiles.isEmpty else { return }
        // 正在执行其他任务时不抢占，稍后重试；否则会被 updateAdmission 直接拒绝。
        guard !isWorking else { return retryLocalSourceSync(reason: reason) }
        let hashes = await Task.detached(priority: .utility) {
            LocalSourceSyncPlanner.contentHashes(for: sourceFiles)
        }.value
        let changed = LocalSourceSyncPlanner.changedModuleIDs(
            sourceFiles: sourceFiles,
            currentHashes: hashes
        )
        guard !changed.isEmpty else {
            if reason == .manual {
                statusMessage = LocalSourceSyncPlanner.detectedStatus(
                    changedCount: 0,
                    firstModuleName: nil
                )
            }
            return
        }
        // 哈希扫描期间可能有其他任务开始执行，这里再确认一次。
        guard !isWorking else { return retryLocalSourceSync(reason: reason) }
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

    private func retryLocalSourceSync(reason: LocalSourceSyncReason) {
        guard reason != .manual else {
            statusMessage = updateAdmission.message
            return
        }
        scheduleLocalSourceSync(after: .seconds(5))
    }
}
