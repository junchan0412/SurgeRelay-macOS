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
    static let overviewSelectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let activitySelectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

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
    var localModuleOutputFolders: [String] = [ModuleOutputFolder.root]
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
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored var githubModuleOutputFoldersLastRefreshedAt: Date?
    @ObservationIgnored var githubModuleOutputFoldersConfiguration: GitHubSettings?
    @ObservationIgnored var localModuleOutputFoldersRootPath: String?
    @ObservationIgnored var localModuleOutputFoldersLastRefreshedAt: Date?
    @ObservationIgnored static let automaticPublishDelaySeconds = 30
    @ObservationIgnored var cachedModuleSummary: ModuleCollectionSummary?
    @ObservationIgnored var cachedWebProjection: WebModuleProjectionCache?
    @ObservationIgnored var modulePreviewDrafts: [UUID: ModulePreviewDraft] = [:]
    /// When true, module mutations during a bulk update skip intermediate disk writes
    /// and high-frequency status text churn that would force full-tree observation.
    @ObservationIgnored var defersModulePersistence = false

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
        if loadedSettings.github.branch.isEmpty { loadedSettings.github.branch = "main" }
        if loadedSettings.github.directory.isEmpty { loadedSettings.github.directory = "modules" }
        loadedSettings.customModuleOutputFolders = ModuleOutputFolder.options(
            from: loadedSettings.customModuleOutputFolders
        ).filter { !$0.isEmpty }
        let loadedModules = ModuleNamingPlanner.normalizedModuleNaming(
            PersistenceStore.loadModules().map { module in
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
        credentialProbe = .notChecked
        selectedModuleID = Self.overviewSelectionID
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
            if let appearance = ProcessInfo.processInfo.environment["SURGE_RELAY_UI_QA_APPEARANCE"] {
                NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
            }
            statusMessage = "UI QA 模式：自动任务已暂停"
            return
        }
        applyAppearancePreference()
        applyWebServerSettings(persist: false)
        startNetworkRecoveryMonitor()
        restartScheduler()
        Task {
            await cleanupLegacyOutputFiles()
            await refreshModuleMetadataFromCache()
            refreshLocalSourceWatching()
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
            // App 未运行期间发生的本地文件改动不会产生 FSEvents 通知，
            // 启动后补扫一次，避免手工编辑的模块一直停留在旧内容。
            await syncChangedLocalSources(reason: .launch)
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
