import AppKit
import Foundation
import Observation

enum AppRuntimeOptions {
    static var isUIQAMode: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.environment["SURGE_RELAY_UI_QA"] == "1" ||
            processInfo.arguments.contains("--surge-relay-ui-qa")
    }
}

@MainActor
@Observable
final class AppModel {
    static let combinedModuleSelectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    var modules: [RelayModule]
    var settings: AppSettings
    var upstreamState: ScriptHubUpstreamState
    var selectedModuleID: UUID?
    var isWorking = false
    var statusMessage = "准备就绪"
    var workActivity: WorkActivity = .idle
    var presentedError: String?
    var githubToken: String
    var webAccessToken: String
    var githubTokenStorageStatus: CredentialStorageStatus
    var webAccessTokenStorageStatus: CredentialStorageStatus
    var keychainAccessProbe: KeychainAccessProbeSnapshot
    var navigationRequest: SidebarDestination?
    /// Set to true to ask the main window to present the in-app settings sheet
    /// (used by the menu bar, the ⌘, command, and the toolbar gear button).
    var presentsSettings = false
    var presentsUpdateChecker = false
    var synchronizationCompletedCount = 0
    var synchronizationTotalCount = 0
    var synchronizingModuleID: UUID?
    var webServerState: WebServerRuntimeState = .stopped
    var updateHistory: [UpdateHistoryEntry]
    var githubModuleOutputFolders: [String] = [ModuleOutputFolder.root]
    var pendingPublishPreview: PublishPreview?
    var automaticPublishScheduledAt: Date?
    var automaticPublishRunsAt: Date?
    var workCancellationRequested = false

    @ObservationIgnored let scriptHubClient = ScriptHubClient()
    @ObservationIgnored let sourceRevisionService = SourceRevisionService()
    @ObservationIgnored let upstreamService = ScriptHubUpstreamService()
    @ObservationIgnored let engineStore = EngineStore()
    @ObservationIgnored let githubClient = GitHubClient()
    @ObservationIgnored let fileStore = ModuleFileStore()
    @ObservationIgnored let iconStore = ModuleIconStore()
    @ObservationIgnored let processingWorker = ModuleProcessingWorker()
    @ObservationIgnored let webServer = WebManagementServer()
    @ObservationIgnored private var foregroundWorkTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundWorkIdentifier = UUID()
    @ObservationIgnored var schedulerTask: Task<Void, Never>?
    @ObservationIgnored var automaticUpdateTask: Task<Void, Never>?
    @ObservationIgnored var automaticPublishTask: Task<Void, Never>?
    @ObservationIgnored var localChangeGeneration = 0
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored var githubModuleOutputFoldersLastRefreshedAt: Date?
    @ObservationIgnored var githubModuleOutputFoldersConfiguration: GitHubSettings?
    @ObservationIgnored static let automaticPublishDelaySeconds = 30

    init() {
        var loadedSettings = PersistenceStore.loadSettings()
        if AppRuntimeOptions.isUIQAMode {
            let uiQAModuleDirectory = FileManager.default.temporaryDirectory
                .appending(path: "SurgeRelayUIQA/Modules", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: uiQAModuleDirectory, withIntermediateDirectories: true)
            loadedSettings.storageMode = .local
            loadedSettings.publishToLocal = true
            loadedSettings.publishToGitHub = false
            loadedSettings.localModuleDirectory = uiQAModuleDirectory.path
        }
        if loadedSettings.github.owner.isEmpty { loadedSettings.github.owner = "EEliberto" }
        if loadedSettings.github.repository.isEmpty { loadedSettings.github.repository = "Surge-Relay" }
        if loadedSettings.github.branch.isEmpty { loadedSettings.github.branch = "main" }
        if loadedSettings.github.directory.isEmpty { loadedSettings.github.directory = "modules" }
        loadedSettings.customModuleOutputFolders = ModuleOutputFolder.options(
            from: loadedSettings.customModuleOutputFolders
        ).filter { !$0.isEmpty }
        let loadedModules = ModuleNamingPlanner.normalizedModuleNaming(
            PersistenceStore.loadModules(),
            combinedFileName: loadedSettings.combinedModuleFileName,
            localModuleDirectory: loadedSettings.localModuleDirectory
        )
        let legacyGitHubToken = loadedSettings.githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        modules = loadedModules
        settings = loadedSettings
        var loadedUpstreamState = PersistenceStore.loadUpstreamState()
        let clearedStaleScriptHubError = Self.clearStaleScriptHubFloatingRevisionError(
            settings: loadedSettings,
            upstreamState: &loadedUpstreamState
        )
        upstreamState = loadedUpstreamState
        updateHistory = PersistenceStore.loadUpdateHistory()
        githubToken = legacyGitHubToken
        webAccessToken = ""
        githubTokenStorageStatus = legacyGitHubToken.isEmpty ? .notChecked : .legacyConfigurationFallback
        webAccessTokenStorageStatus = .notChecked
        keychainAccessProbe = .notChecked
        selectedModuleID = loadedSettings.combinedModuleEnabled
            ? Self.combinedModuleSelectionID
            : loadedModules.first?.id
        if !AppRuntimeOptions.isUIQAMode {
            PersistenceStore.saveSettings(loadedSettings)
            try? PersistenceStore.saveModules(loadedModules)
            if clearedStaleScriptHubError {
                PersistenceStore.saveUpstreamState(loadedUpstreamState)
            }
        }
    }

    private static func clearStaleScriptHubFloatingRevisionError(
        settings: AppSettings,
        upstreamState: inout ScriptHubUpstreamState
    ) -> Bool {
        guard settings.scriptHubModuleURL == AppSettings.defaultScriptHubModuleURL,
              let lastError = upstreamState.lastError,
              lastError.contains("固定 tag 或 commit") else {
            return false
        }
        upstreamState.lastError = nil
        return true
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        guard !AppRuntimeOptions.isUIQAMode else {
            statusMessage = "UI QA 模式：自动任务已暂停"
            return
        }
        applyWebServerSettings(persist: false)
        restartScheduler()
        Task {
            await cleanupLegacyOutputFiles()
            await refreshModuleMetadataFromCache()
            let missingEngine = !(await engineStore.hasScript(named: "Rewrite-Parser.js"))
            if await ModuleRefreshPlanner.shouldUpdateOnLaunch(
                modules: modules,
                combinedModuleEnabled: settings.combinedModuleEnabled,
                refreshIntervalMinutes: settings.refreshIntervalMinutes,
                componentExists: { [fileStore] id in
                    await fileStore.hasComponent(id: id)
                }
            ) {
                await updateAll()
            } else if UpdateCoordinator.shouldRefreshScriptHub(
                missingEngine: missingEngine,
                settings: settings,
                upstreamState: upstreamState
            ) {
                await refreshScriptHub(showProgress: false)
            } else if modules.contains(where: shouldUpdateModule) {
                statusMessage = "模块仍在刷新周期内，无需重新加载"
            }
        }
    }

    func saveSettings() {
        settings.storageMode = settings.publishToGitHub ? .gitHub : .local
        if !settings.publishToGitHub || !settings.automaticallyPublish {
            cancelAutomaticPublishSchedule()
        }
        PersistenceStore.saveSettings(settings)
    }

    func setCombinedModuleEnabled(_ enabled: Bool) {
        guard settings.combinedModuleEnabled != enabled else { return }
        settings.combinedModuleEnabled = enabled
        if !enabled, selectedModuleID == Self.combinedModuleSelectionID {
            selectedModuleID = modules.first?.id
        } else if enabled, selectedModuleID == nil {
            selectedModuleID = Self.combinedModuleSelectionID
        }
        saveSettings()
        statusMessage = enabled ? "总模块功能已开启，正在准备合并" : "总模块功能已关闭"
        Task { await rebuildCombinedFromCache() }
    }

    func startUpdateAll() {
        let admission = updateAdmission
        guard admission.isAccepted else {
            statusMessage = admission.message
            return
        }
        startForegroundWork { model in
            await model.updateAll()
        }
    }

    func startUpdate(moduleID: UUID) {
        guard let module = modules.first(where: { $0.id == moduleID }) else { return }
        let admission = updateAdmission(for: module)
        guard admission.isAccepted else {
            statusMessage = admission.message
            return
        }
        startForegroundWork { model in
            await model.update(moduleID: moduleID)
        }
    }

    @discardableResult
    func cancelCurrentWork() -> Bool {
        guard workActivity.isActive else {
            statusMessage = "没有正在执行的任务可取消"
            return false
        }
        guard workActivity.canCancel else {
            statusMessage = "当前任务不能取消"
            return false
        }
        guard !workCancellationRequested else { return true }
        workCancellationRequested = true
        statusMessage = "正在取消\(workActivity.title)…"
        foregroundWorkTask?.cancel()
        automaticUpdateTask?.cancel()
        if workActivity.kind == .automaticPublishing {
            automaticPublishTask?.cancel()
        }
        return true
    }

    func clearUpdateHistory() {
        updateHistory.removeAll()
        PersistenceStore.saveUpdateHistory([])
    }

    private func startForegroundWork(_ operation: @escaping @MainActor (AppModel) async -> Void) {
        foregroundWorkTask?.cancel()
        let identifier = UUID()
        foregroundWorkIdentifier = identifier
        foregroundWorkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await operation(self)
            if self.foregroundWorkIdentifier == identifier {
                self.foregroundWorkTask = nil
            }
        }
    }

    func shouldContinueCurrentWork(
        generation: Int? = nil,
        staleMessage: String = "检测到新的修改，已放弃旧更新"
    ) -> Bool {
        if workCancellationRequested || Task.isCancelled {
            statusMessage = "正在取消\(workActivity.title)…"
            return false
        }
        if let generation, generation != localChangeGeneration {
            statusMessage = staleMessage
            return false
        }
        return true
    }

    func checkCurrentWorkCancellation() throws {
        guard !workCancellationRequested, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    func enterNonCancellableWorkPhase(statusMessage message: String) throws {
        try checkCurrentWorkCancellation()
        guard workActivity.isActive else { return }
        workCancellationRequested = false
        workActivity.canCancel = false
        statusMessage = message
    }

    func isCurrentWorkCancellation(_ error: any Error) -> Bool {
        error is CancellationError || workCancellationRequested || Task.isCancelled
    }

    func beginWork(_ kind: WorkActivityKind, blocksUpdates: Bool? = nil) {
        let activity = WorkActivity(kind: kind, blocksUpdates: blocksUpdates)
        workCancellationRequested = false
        workActivity = activity
        isWorking = activity.blocksUpdates
    }

    func endWork(_ kind: WorkActivityKind? = nil) {
        if kind == nil || workActivity.kind == kind {
            let wasCancelling = workCancellationRequested || Task.isCancelled
            let title = workActivity.title
            workActivity = .idle
            isWorking = false
            workCancellationRequested = false
            if wasCancelling {
                statusMessage = "已取消\(title)"
            }
        }
    }

    func recordHistory(_ entries: [UpdateHistoryEntry]) {
        guard !entries.isEmpty else { return }
        updateHistory = Array((entries.reversed() + updateHistory).prefix(200))
        PersistenceStore.saveUpdateHistory(updateHistory)
    }

    var modulePreviewProvider: ModulePreviewContentProvider {
        ModulePreviewContentProvider(
            hasComponent: { [fileStore] id in
                await fileStore.hasComponent(id: id)
            },
            readComponent: { [fileStore] id in
                try await fileStore.readComponent(id: id)
            },
            readConvertedComponent: { [fileStore] id in
                try await fileStore.readConvertedComponent(id: id)
            },
            writeComponent: { [fileStore] content, id in
                try await fileStore.writeComponent(content, id: id)
            },
            readCombined: { [fileStore] in
                try await fileStore.readCombined()
            },
            materialize: { [processingWorker] content, overrides in
                await processingWorker.materialize(content, overrides: overrides)
            },
            argumentInfo: { [processingWorker] content in
                await processingWorker.argumentInfo(in: content)
            },
            applyingModuleMetadata: { [processingWorker] name, category, content in
                await processingWorker.applyingModuleMetadata(
                    name: name,
                    category: category,
                    to: content
                )
            }
        )
    }

}
