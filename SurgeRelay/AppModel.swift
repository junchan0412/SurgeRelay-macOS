import AppKit
import Foundation
import Observation

enum AppRuntimeOptions {
    static var isUIQAMode: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.environment["SURGE_RELAY_UI_QA"] == "1" ||
            processInfo.arguments.contains("--surge-relay-ui-qa") ||
            (Bundle.main.object(forInfoDictionaryKey: "SurgeRelayUIQA") as? Bool == true)
    }

    static var uiQADirectory: URL {
        let configured = ProcessInfo.processInfo.environment["SURGE_RELAY_UI_QA_ROOT"]
            ?? (Bundle.main.object(forInfoDictionaryKey: "SurgeRelayUIQARoot") as? String)
        if let configured, configured.hasPrefix("/") {
            return URL(filePath: configured, directoryHint: .isDirectory).standardizedFileURL
        }
        return FileManager.default.temporaryDirectory.appending(path: "SurgeRelayUIQA", directoryHint: .isDirectory)
    }
}

@MainActor
@Observable
final class AppModel {
    static let combinedModuleSelectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let overviewSelectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let activitySelectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    let workspaceID: UUID
    var workspaceName: String
    let cacheDirectoryURL: URL
    let isLegacyWorkspace: Bool
    let runtimeID = UUID()
    @ObservationIgnored var webSnapshotRevision: UInt64 = 0
    var workspaceIsActive = true
    var isWorkspaceTransitioning = false
    @ObservationIgnored var configurationRelocationCommit: (@Sendable (URL) throws -> Void)?
    @ObservationIgnored var configurationRelocationValidation: (@MainActor (URL) throws -> Void)?
    @ObservationIgnored var configurationRelocationFinished: (@MainActor (URL) -> Void)?
    @ObservationIgnored var startupRecoveryFailed = false
    @ObservationIgnored var startupRecoveryPending = false
    @ObservationIgnored var startupTask: Task<Void, Never>?
    @ObservationIgnored var stageProgressTask: Task<Void, Never>?
    @ObservationIgnored var activeStageProgress: [UUID: WorkStageProgress] = [:]

    var modules: [RelayModule] {
        didSet {
            moduleRevision &+= 1
            cachedModuleSummary = nil
        }
    }
    private(set) var moduleRevision: UInt64 = 0
    var settings: AppSettings {
        didSet {
            if oldValue.combinedModuleEnabled != settings.combinedModuleEnabled {
                cachedModuleSummary = nil
            }
        }
    }
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
    var credentialProbe: LocalCredentialProbeSnapshot
    /// Set to true to ask the main window to present the in-app settings sheet
    /// (used by the menu bar, the ⌘, command, and the toolbar gear button).
    var presentsSettings = false
    var settingsPage: SettingsPage = .general
    var presentsUpdateChecker = false
    var synchronizationCompletedCount = 0
    var synchronizationTotalCount = 0
    var synchronizingModuleIDs: Set<UUID> = []
    var synchronizingModuleID: UUID? { modules.first { synchronizingModuleIDs.contains($0.id) }?.id }
    var webServerState: WebServerRuntimeState = .stopped
    var updateHistory: [UpdateHistoryEntry]
    var moduleTemplates: [ModuleTemplate]
    var localModuleOutputFolders: [String] = [ModuleOutputFolder.root]
    var githubModuleOutputFolders: [String] = [ModuleOutputFolder.root]
    var selectedPublishAttempt: SelectedPublishAttempt?
    var pendingSelectedPublishLintReview: SelectedPublishLintReview?
    var pendingPublishPreview: PublishPreview?
    var automaticPublishScheduledAt: Date?
    var automaticPublishRunsAt: Date?
    var workCancellationRequested = false

    var persistenceError: String?
    var configurationStorageDirectory: URL
    @ObservationIgnored let configurationWriter: ConfigurationPersistenceWriter
    @ObservationIgnored var configurationWriteRevision: UInt64 = 0
    @ObservationIgnored var persistenceFeedbackTask: Task<Void, Never>?
    @ObservationIgnored var configurationMigrationTask: Task<Void, Never>?

    @ObservationIgnored let scriptHubClient: ScriptHubClient
    @ObservationIgnored let sourceRevisionService: SourceRevisionService
    @ObservationIgnored let upstreamService: ScriptHubUpstreamService
    @ObservationIgnored let engineStore: EngineStore
    @ObservationIgnored let githubClient: GitHubClient
    @ObservationIgnored let fileStore: ModuleFileStore
    @ObservationIgnored let iconStore: ModuleIconStore
    @ObservationIgnored let processingWorker = ModuleProcessingWorker()
    @ObservationIgnored let webServer = WebManagementServer()
    @ObservationIgnored let networkPathMonitor = NetworkPathMonitor()
    @ObservationIgnored let localSourceWatcher = LocalSourceWatcher()
    @ObservationIgnored var foregroundWorkTask: Task<Void, Never>?
    @ObservationIgnored var moduleUpdateTask: Task<[ModuleUpdateOutcome?], Never>?
    @ObservationIgnored var updatePreparationTask: Task<Void, Never>?
    @ObservationIgnored var foregroundWorkIdentifier = UUID()
    @ObservationIgnored var schedulerTask: Task<Void, Never>?
    @ObservationIgnored var automaticUpdateTask: Task<Void, Never>?
    @ObservationIgnored var automaticPublishTask: Task<Void, Never>?
    @ObservationIgnored var localSourceWatcherTask: Task<Void, Never>?
    @ObservationIgnored var localSourceSyncTask: Task<Void, Never>?
    @ObservationIgnored var localChangeGeneration = 0
    @ObservationIgnored var hasStarted = false
    @ObservationIgnored var githubModuleOutputFoldersLastRefreshedAt: Date?
    @ObservationIgnored var githubModuleOutputFoldersConfiguration: GitHubSettings?
    @ObservationIgnored var localModuleOutputFoldersRootPath: String?
    @ObservationIgnored var localModuleOutputFoldersLastRefreshedAt: Date?
    @ObservationIgnored static let automaticPublishDelaySeconds = 30
    @ObservationIgnored var cachedModuleSummary: ModuleCollectionSummary?
    @ObservationIgnored var cachedWebProjection: WebModuleProjectionCache?
    @ObservationIgnored let webActionTickets = WebActionTickets()
    @ObservationIgnored var modulePreviewDrafts: [UUID: ModulePreviewDraft] = [:] {
        didSet { schedulePreviewDraftPersistence() }
    }
    var restoredPreviewDraftIDs: Set<UUID> = []
    var previewDraftPersistenceError: String?
    @ObservationIgnored let previewDraftWriter = PreviewDraftWriter()
    @ObservationIgnored var previewDraftPersistenceTask: Task<Void, Never>?
    @ObservationIgnored var previewDraftRevision: UInt64 = 0
    /// When true, module mutations during a bulk update skip intermediate disk writes
    /// and high-frequency status text churn that would force full-tree observation.
    @ObservationIgnored var defersModulePersistence = false

    init(context: WorkspaceContext? = nil, githubClient: GitHubClient? = nil, persistsOnInit: Bool = true) {
        let contextValue = context ?? WorkspaceContext.legacyDefault
        workspaceID = contextValue.id
        workspaceName = contextValue.name
        cacheDirectoryURL = contextValue.cacheDirectory
        isLegacyWorkspace = contextValue.id == WorkspaceContext.legacyID
        configurationStorageDirectory = contextValue.configurationDirectory
        configurationWriter = ConfigurationPersistenceWriter(directory: contextValue.configurationDirectory)
        let session = URLSession(configuration: .ephemeral)
        self.githubClient = githubClient ?? GitHubClient(session: session)
        let engine = EngineStore(cacheDirectory: contextValue.cacheDirectory)
        engineStore = engine
        scriptHubClient = ScriptHubClient(engineStore: engine, session: session)
        sourceRevisionService = SourceRevisionService(session: session)
        upstreamService = ScriptHubUpstreamService(session: session)
        fileStore = ModuleFileStore(cacheDirectory: contextValue.cacheDirectory, configurationDirectory: contextValue.configurationDirectory,
                                    allowsLegacyFallback: contextValue.allowsLegacyFallback)
        iconStore = ModuleIconStore(cacheDirectory: contextValue.cacheDirectory, session: session)
        var loadedSettings = PersistenceStore.loadSettings(in: contextValue.configurationDirectory, allowLegacyFallback: contextValue.allowsLegacyFallback)
        if AppRuntimeOptions.isUIQAMode, context == nil || (contextValue.id == WorkspaceContext.legacyID && contextValue.configurationDirectory == PersistenceStore.configurationDirectoryURL) {
            let uiQAModuleDirectory = AppRuntimeOptions.uiQADirectory.appending(path: "Modules", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: uiQAModuleDirectory, withIntermediateDirectories: true)
            loadedSettings.storageMode = .local
            loadedSettings.publishToLocal = true
            loadedSettings.publishToGitHub = false
            loadedSettings.localModuleDirectory = uiQAModuleDirectory.path
        }
        if loadedSettings.github.branch.isEmpty { loadedSettings.github.branch = "main" }
        if loadedSettings.github.directory.isEmpty { loadedSettings.github.directory = "modules" }
        loadedSettings.customModuleOutputFolders = ModuleOutputFolder.options(
            from: loadedSettings.customModuleOutputFolders
        ).filter { !$0.isEmpty }
        let loadedModules = ModuleNamingPlanner.normalizedModuleNaming(
            PersistenceStore.loadModules(in: contextValue.configurationDirectory, allowLegacyFallback: contextValue.allowsLegacyFallback).map { module in
                var module = module
                module.state = ModuleUpdatePipeline.restoredState(for: module)
                return module
            },
            combinedFileName: loadedSettings.combinedModuleFileName,
            localModuleDirectory: loadedSettings.localModuleDirectory
        )
        let legacyGitHubToken = loadedSettings.githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        modules = loadedModules
        settings = loadedSettings
        var loadedUpstreamState = PersistenceStore.loadUpstreamState(in: contextValue.configurationDirectory, allowLegacyFallback: contextValue.allowsLegacyFallback)
        let clearedStaleScriptHubError = Self.clearStaleScriptHubFloatingRevisionError(
            settings: loadedSettings,
            upstreamState: &loadedUpstreamState
        )
        upstreamState = loadedUpstreamState
        updateHistory = PersistenceStore.loadUpdateHistory(in: contextValue.configurationDirectory)
        moduleTemplates = PersistenceStore.loadModuleTemplates(in: contextValue.configurationDirectory)
        selectedPublishAttempt = PersistenceStore.loadSelectedPublishAttempt(in: contextValue.configurationDirectory)
        let drafts = PersistenceStore.loadPreviewDrafts(in: contextValue.configurationDirectory).filter { id, _ in loadedModules.contains { $0.id == id } }
        modulePreviewDrafts = drafts
        restoredPreviewDraftIDs = Set(drafts.keys)
        githubToken = legacyGitHubToken
        webAccessToken = ""
        githubTokenStorageStatus = legacyGitHubToken.isEmpty ? .notChecked : .legacyConfigurationFallback
        webAccessTokenStorageStatus = .notChecked
        credentialProbe = .notChecked
        selectedModuleID = Self.overviewSelectionID
        if persistsOnInit, !AppRuntimeOptions.isUIQAMode {
            enqueueConfiguration(loadedSettings, fileName: "settings.json")
            enqueueConfiguration(loadedModules, fileName: "modules.json")
            if clearedStaleScriptHubError {
                enqueueConfiguration(loadedUpstreamState, fileName: "script-hub-state.json")
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

    func start(performLaunchRefresh: Bool = true) {
        guard !hasStarted, workspaceIsActive, !isWorkspaceTransitioning else { return }
        hasStarted = true
        guard !AppRuntimeOptions.isUIQAMode else {
            if let appearance = ProcessInfo.processInfo.environment["SURGE_RELAY_UI_QA_APPEARANCE"] {
                NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
            }
            statusMessage = "UI QA 模式：自动任务已暂停"
            return
        }
        applyAppearancePreference()
        startupRecoveryPending = true
        beginWork(.restoringPreview)
        workActivity.title = "检查恢复记录"
        startupTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await recoverPersistedVersionState()
                try await reconcileRecoveredLocalResources()
            } catch {
                endWork(.restoringPreview)
                hasStarted = false
                startupRecoveryFailed = true
                startupRecoveryPending = false
                presentedError = "启动恢复未完成，自动任务与 Web 服务暂未启动：\(error.localizedDescription)"
                return
            }
            startupRecoveryFailed = false
            startupRecoveryPending = false
            endWork(.restoringPreview)
            guard !Task.isCancelled, workspaceIsActive, !isWorkspaceTransitioning else { return }
            applyWebServerSettings(persist: false)
            startNetworkRecoveryMonitor()
            restartScheduler()
            if isLegacyWorkspace { await cleanupLegacyOutputFiles() }
            guard !Task.isCancelled, workspaceIsActive else { return }
            await refreshModuleMetadataFromCache()
            guard !Task.isCancelled, workspaceIsActive else { return }
            refreshLocalSourceWatching()
            if !performLaunchRefresh {
                await syncChangedLocalSources(reason: .launch)
                return
            }
            let missingEngine = !(await engineStore.hasScript(named: "Rewrite-Parser.js"))
            if settings.automaticallyUpdateOnLaunch,
               await ModuleRefreshPlanner.shouldUpdateOnLaunch(
                   modules: modules,
                   combinedModuleEnabled: settings.combinedModuleEnabled,
                   refreshIntervalMinutes: settings.refreshIntervalMinutes,
                   componentExists: { [fileStore] id in
                       await fileStore.hasComponent(id: id)
                   }
               ) {
                await updateAll(trigger: .launch)
            } else if UpdateCoordinator.shouldRefreshScriptHub(
                missingEngine: missingEngine,
                settings: settings,
                upstreamState: upstreamState
            ) {
                await refreshScriptHub(showProgress: false)
            } else if modules.contains(where: shouldUpdateModule) {
                statusMessage = "模块仍在刷新周期内，无需重新加载"
            }
            // App 未运行期间发生的本地文件改动不会产生 FSEvents 通知，
            // 启动后补扫一次，避免手工编辑的模块一直停留在旧内容。
            guard !Task.isCancelled, workspaceIsActive else { return }
            await syncChangedLocalSources(reason: .launch)
        }
    }

    func saveSettings() {
        settings.storageMode = settings.publishToGitHub ? .gitHub : .local
        if !settings.publishToGitHub || !settings.automaticallyPublish {
            cancelAutomaticPublishSchedule()
        }
        enqueueConfiguration(settings, fileName: "settings.json")
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
            applyingModuleMetadata: { [processingWorker] name, category, desc, iconURL, content in
                await processingWorker.applyingModuleMetadata(
                    name: name,
                    category: category,
                    desc: desc,
                    iconURL: iconURL,
                    to: content
                )
            }
        )
    }

}
