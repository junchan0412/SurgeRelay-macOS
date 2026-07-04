import AppKit
import Foundation
import Observation
import Security

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

    @ObservationIgnored private let scriptHubClient = ScriptHubClient()
    @ObservationIgnored private let sourceRevisionService = SourceRevisionService()
    @ObservationIgnored private let upstreamService = ScriptHubUpstreamService()
    @ObservationIgnored private let engineStore = EngineStore()
    @ObservationIgnored private let githubClient = GitHubClient()
    @ObservationIgnored private let fileStore = ModuleFileStore()
    @ObservationIgnored private let iconStore = ModuleIconStore()
    @ObservationIgnored private let processingWorker = ModuleProcessingWorker()
    @ObservationIgnored private let webServer = WebManagementServer()
    @ObservationIgnored private var foregroundWorkTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundWorkIdentifier = UUID()
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?
    @ObservationIgnored private var automaticUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var automaticPublishTask: Task<Void, Never>?
    @ObservationIgnored private var localChangeGeneration = 0
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var githubModuleOutputFoldersLastRefreshedAt: Date?
    @ObservationIgnored private var githubModuleOutputFoldersConfiguration: GitHubSettings?
    @ObservationIgnored private static let automaticPublishDelaySeconds = 30

    private struct GitHubTokenLoadResult {
        var token: String
        var storageStatus: CredentialStorageStatus
        var shouldClearLegacyToken: Bool
        var statusMessage: String?
    }

    private struct WebAccessTokenLoadResult {
        var token: String
        var storageStatus: CredentialStorageStatus
        var statusMessage: String?
    }

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

    private static func loadGitHubToken(migratingLegacyToken legacyToken: String) -> GitHubTokenLoadResult {
        let legacyToken = legacyToken.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let storedToken = try KeychainStore.loadGitHubToken()
            if !storedToken.isEmpty {
                return GitHubTokenLoadResult(
                    token: storedToken,
                    storageStatus: .keychain,
                    shouldClearLegacyToken: true,
                    statusMessage: legacyToken.isEmpty ? nil : "GitHub Token 已改由系统钥匙串管理"
                )
            }
            guard !legacyToken.isEmpty else {
                return GitHubTokenLoadResult(
                    token: "",
                    storageStatus: .notConfigured,
                    shouldClearLegacyToken: true
                )
            }
            try KeychainStore.saveGitHubToken(legacyToken)
            return GitHubTokenLoadResult(
                token: legacyToken,
                storageStatus: .keychain,
                shouldClearLegacyToken: true,
                statusMessage: "GitHub Token 已从同步配置迁移到系统钥匙串"
            )
        } catch {
            guard !legacyToken.isEmpty else {
                return GitHubTokenLoadResult(
                    token: "",
                    storageStatus: .unavailable,
                    shouldClearLegacyToken: false
                )
            }
            return GitHubTokenLoadResult(
                token: legacyToken,
                storageStatus: .legacyConfigurationFallback,
                shouldClearLegacyToken: false,
                statusMessage: "无法访问系统钥匙串，暂时沿用旧同步配置中的 GitHub Token"
            )
        }
    }

    private static func loadWebAccessToken() -> WebAccessTokenLoadResult {
        do {
            let storedToken = try KeychainStore.loadWebAccessToken()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !storedToken.isEmpty {
                return WebAccessTokenLoadResult(token: storedToken, storageStatus: .keychain)
            }
            let token = generateWebAccessToken()
            try KeychainStore.saveWebAccessToken(token)
            return WebAccessTokenLoadResult(token: token, storageStatus: .keychain)
        } catch {
            return WebAccessTokenLoadResult(
                token: generateWebAccessToken(),
                storageStatus: .memoryOnly,
                statusMessage: "无法访问系统钥匙串，Web 管理访问令牌仅在本次运行中有效"
            )
        }
    }

    private static func generateWebAccessToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        if status == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    @discardableResult
    func ensureGitHubTokenLoaded(showStatusMessage: Bool = false) -> String {
        let legacyToken = settings.githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldLoad = githubTokenStorageStatus == .notChecked ||
            (githubTokenStorageStatus == .legacyConfigurationFallback && !legacyToken.isEmpty)
        guard shouldLoad else {
            return githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let tokenLoad = Self.loadGitHubToken(migratingLegacyToken: settings.githubToken)
        githubToken = tokenLoad.token
        githubTokenStorageStatus = tokenLoad.storageStatus
        if tokenLoad.shouldClearLegacyToken {
            settings.githubToken = ""
            PersistenceStore.saveSettings(settings)
        }
        if showStatusMessage, let message = tokenLoad.statusMessage {
            statusMessage = message
        }
        return tokenLoad.token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func ensureWebAccessTokenLoaded(showStatusMessage: Bool = false) -> String {
        let current = webAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.isEmpty || webAccessTokenStorageStatus == .notChecked else { return current }

        let tokenLoad = Self.loadWebAccessToken()
        webAccessToken = tokenLoad.token
        webAccessTokenStorageStatus = tokenLoad.storageStatus
        if showStatusMessage, let message = tokenLoad.statusMessage {
            statusMessage = message
        }
        return tokenLoad.token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func ensureWebAccessTokenForEditing(showStatusMessage: Bool = false) -> String {
        ensureWebAccessTokenLoaded(showStatusMessage: showStatusMessage)
    }

    func saveWebAccessToken() {
        webAccessToken = webAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !webAccessToken.isEmpty else {
            presentedError = "Web 管理令牌不能为空。可以点击“生成新令牌”后保存。"
            statusMessage = "Web 管理令牌未保存"
            return
        }
        do {
            try KeychainStore.saveWebAccessToken(webAccessToken)
            webAccessTokenStorageStatus = .keychain
            statusMessage = "Web 管理访问令牌已保存到系统钥匙串"
        } catch {
            webAccessTokenStorageStatus = .memoryOnly
            presentedError = "无法保存 Web 管理访问令牌：\(error.localizedDescription)"
            statusMessage = "Web 管理访问令牌仅在本次运行中有效"
        }
        applyWebServerSettings()
    }

    func resetWebAccessToken() {
        let token = Self.generateWebAccessToken()
        webAccessToken = token
        do {
            try KeychainStore.saveWebAccessToken(token)
            webAccessTokenStorageStatus = .keychain
            statusMessage = "Web 管理访问令牌已重置"
        } catch {
            webAccessTokenStorageStatus = .memoryOnly
            presentedError = "无法保存 Web 管理访问令牌：\(error.localizedDescription)"
            statusMessage = "Web 管理访问令牌仅在本次运行中有效"
        }
        applyWebServerSettings()
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
            if await shouldUpdateModulesOnLaunch() {
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

    private func shouldUpdateModulesOnLaunch() async -> Bool {
        let updateModules = modules.filter(shouldUpdateModule)
        guard !updateModules.isEmpty else { return false }

        for module in updateModules {
            if module.lastUpdatedAt == nil { return true }
            if !(await fileStore.hasComponent(id: module.id)) { return true }
        }

        let oldestUpdate = updateModules.compactMap(\.lastUpdatedAt).min()
        return RefreshPolicy.isDue(
            lastUpdatedAt: oldestUpdate,
            intervalMinutes: settings.refreshIntervalMinutes
        )
    }

    func saveSettings() {
        settings.storageMode = settings.publishToGitHub ? .gitHub : .local
        if !settings.publishToGitHub || !settings.automaticallyPublish {
            cancelAutomaticPublishSchedule()
        }
        PersistenceStore.saveSettings(settings)
    }

    private func shouldContributeToCombined(_ module: RelayModule) -> Bool {
        settings.combinedModuleEnabled && module.isEnabled
    }

    private func shouldUpdateModule(_ module: RelayModule) -> Bool {
        module.hasRemoteOriginalSource || shouldContributeToCombined(module) || module.publishesStandalone
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

    var updateAdmission: UpdateAdmission {
        UpdateAdmission.allModules(
            activity: workActivity,
            updateableModuleCount: updateableModuleCount,
            statusMessage: statusMessage
        )
    }

    func updateAdmission(for module: RelayModule) -> UpdateAdmission {
        UpdateAdmission.module(
            module,
            moduleIsUpdateable: shouldUpdateModule(module),
            activity: workActivity,
            updateableModuleCount: updateableModuleCount,
            statusMessage: statusMessage
        )
    }

    var moduleSummary: ModuleCollectionSummary {
        ModuleCollectionSummary(modules: modules, isUpdateable: shouldUpdateModule)
    }

    var updateableModuleCount: Int {
        moduleSummary.updateableCount
    }

    var canCancelCurrentWork: Bool {
        workActivity.isActive && workActivity.canCancel && !workCancellationRequested
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

    func saveGitHubToken() {
        githubToken = githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try KeychainStore.saveGitHubToken(githubToken)
            settings.githubToken = ""
            githubTokenStorageStatus = githubToken.isEmpty ? .notConfigured : .keychain
            PersistenceStore.saveSettings(settings)
            statusMessage = githubToken.isEmpty ? "GitHub Token 已从系统钥匙串移除" : "GitHub Token 已保存到系统钥匙串"
        } catch {
            githubTokenStorageStatus = githubToken.isEmpty ? .unavailable : .memoryOnly
            presentedError = "无法保存 GitHub Token：\(error.localizedDescription)"
            statusMessage = "GitHub Token 未保存"
        }
    }

    func applyWebServerSettings(persist: Bool = true) {
        guard (1...65_535).contains(settings.webServerPort),
              let port = UInt16(exactly: settings.webServerPort) else {
            webServerState = .failed("端口必须在 1–65535 之间。")
            return
        }
        if persist { saveSettings() }
        webServer.stop()
        guard settings.webServerEnabled else {
            webServerState = .stopped
            return
        }

        let token = ensureWebAccessTokenLoaded(showStatusMessage: true)
        guard !token.isEmpty else {
            webServerState = .failed("无法生成 Web 管理访问令牌。")
            return
        }

        let configuration = WebServerConfiguration(
            port: port,
            allowRemoteAccess: settings.webServerAllowRemoteAccess,
            accessToken: token
        )
        do {
            try webServer.start(
                configuration: configuration,
                stateHandler: { [weak self] state in
                    Task { @MainActor [weak self] in self?.webServerState = state }
                },
                eventHandler: { [weak self] in
                    guard let self else { return "{}" }
                    return await WebManagementAPI.eventPayload(model: self)
                },
                requestHandler: { [weak self] request in
                    if !request.path.hasPrefix("/api/") {
                        return WebManagementAPI.assetResponse(for: request.path)
                    }
                    guard let self else {
                        return .error(status: 500, message: "Surge Relay 已停止。")
                    }
                    return await WebManagementAPI.response(for: request, model: self)
                }
            )
        } catch {
            webServerState = .failed(error.localizedDescription)
        }
    }


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

    func setStorageMode(_ mode: StorageMode) {
        let nextLocal = mode == .local
        let nextGitHub = mode == .gitHub
        guard settings.publishToLocal != nextLocal || settings.publishToGitHub != nextGitHub else { return }
        settings.storageMode = mode
        settings.publishToLocal = nextLocal
        settings.publishToGitHub = nextGitHub
        saveSettings()
        if mode == .local {
            Task { await rebuildCombinedFromCache() }
        } else {
            Task { await refreshModuleOutputFolders(force: true) }
        }
    }

    func setLocalModuleDirectory(_ path: String) {
        settings.localModuleDirectory = path
        saveSettings()
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

    func scanExistingLocalModules() async throws -> LocalModuleScanReport {
        guard !isWorking else {
            throw RelayError.invalidOutput(updateAdmission.message)
        }
        beginWork(.scanningLocalModules)
        defer { endWork(.scanningLocalModules) }
        statusMessage = "正在扫描本地模块根目录…"
        let rootDirectoryPath = settings.localModuleDirectory
        let combinedFileName = settings.combinedModuleFileName
        let existingModules = modules
        let publishedFilePaths = settings.localPublishedFilePaths
        let report = try await Task.detached(priority: .userInitiated) {
            try LocalModuleScanner.report(
                in: rootDirectoryPath,
                combinedFileName: combinedFileName,
                existingModules: existingModules,
                publishedFilePaths: publishedFilePaths
            )
        }.value
        guard shouldContinueCurrentWork() else {
            return LocalModuleScanReport(candidates: [], skippedFiles: [])
        }
        if report.candidates.isEmpty {
            statusMessage = report.skippedFiles.isEmpty
                ? "未发现可导入的新本地模块"
                : "未发现可导入的新本地模块；已跳过 \(report.skippedFiles.count) 个文件"
        } else {
            let skippedSuffix = report.skippedFiles.isEmpty ? "" : "，跳过 \(report.skippedFiles.count) 个文件"
            statusMessage = "发现 \(report.candidates.count) 个可导入本地模块\(skippedSuffix)"
        }
        return report
    }

    func importExistingLocalModules() async {
        guard !isWorking else { return }
        do {
            let report = try await scanExistingLocalModules()
            await importLocalModules(report.candidates)
        } catch {
            presentedError = "扫描本地模块失败：\(error.localizedDescription)"
            statusMessage = "本地模块扫描失败"
        }
    }

    func importLocalModules(_ candidates: [LocalModuleScanCandidate]) async {
        guard !isWorking else { return }
        guard !candidates.isEmpty else {
            statusMessage = "没有选择需要导入的本地模块"
            return
        }
        beginWork(.importingLocalModules)
        defer { endWork(.importingLocalModules) }

        registerLocalChange()
        var imported: [RelayModule] = []
        var failures: [String] = []
        var unavailablePaths = Set(modules.map { $0.publishedRelativePath.lowercased() })
        let combinedPath = ModuleOutputFolder.relativePath(
            fileName: settings.combinedModuleFileName,
            folder: ModuleOutputFolder.root
        ).lowercased()
        unavailablePaths.insert(combinedPath)

        for candidate in candidates {
            guard shouldContinueCurrentWork() else { return }
            let name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                failures.append("\(candidate.relativePath)：模块名称不能为空")
                continue
            }
            let outputFolder = ModuleOutputFolder.normalized(candidate.outputFolder)
            let outputFileName = ModuleNamingPlanner.uniqueOutputFileName(
                preferredFileName: candidate.outputFileName,
                folder: outputFolder,
                unavailable: unavailablePaths,
                preservesExistingFileName: true
            )
            unavailablePaths.insert(
                ModuleOutputFolder.relativePath(
                    fileName: outputFileName,
                    folder: outputFolder,
                    preservesExistingFileName: true
                ).lowercased()
            )
            var module = RelayModule(
                name: name,
                sourceURL: candidate.sourceURL,
                sourceFormat: candidate.sourceFormat,
                outputFileName: outputFileName,
                category: candidate.category,
                outputFolder: outputFolder,
                storageLocation: .local,
                localStorageRelativePath: candidate.localStorageRelativePath,
                preservesOutputFileName: true,
                isEnabled: false,
                scriptHubOptions: candidate.scriptHubOptions,
                scriptHubSubscription: candidate.scriptHubSubscription,
                detectedSourceFormat: candidate.sourceFormat == .automatic ? nil : candidate.sourceFormat,
                sourceContentHash: candidate.sourceContentHash,
                sourceCheckedAt: .now
            )
            do {
                let result = try await scriptHubClient.convert(
                    module: module,
                    github: settings.github.isConfigured ? settings.github : nil
                )
                if let subscription = ModuleMetadataParser.scriptHubSubscription(in: result.content) {
                    _ = module.applyScriptHubSubscriptionMetadata(subscription)
                }
                try await fileStore.writeComponent(result.content, id: module.id)
                let fingerprint = await processingWorker.contentFingerprint(
                    of: result.content,
                    assets: result.assets
                )
                module.contentHash = fingerprint
                module.lastUpdatedAt = .now
                module.state = .current
                module.lastError = nil
                imported.append(module)
            } catch {
                guard shouldContinueCurrentWork() else { return }
                failures.append("\(candidate.relativePath)：\(error.localizedDescription)")
            }
        }

        guard shouldContinueCurrentWork() else { return }

        guard !imported.isEmpty else {
            statusMessage = "本地模块扫描完成，但没有可导入项目"
            if !failures.isEmpty {
                presentedError = "以下本地模块无法导入：\n\(failures.joined(separator: "\n"))"
            }
            return
        }

        modules.append(contentsOf: imported)
        selectedModuleID = imported.first?.id
        do {
            try persistModules()
        } catch {
            presentedError = "保存导入模块失败：\(error.localizedDescription)"
        }
        await rebuildCombinedFromCache()
        let failureSuffix = failures.isEmpty ? "" : "；\(failures.count) 个文件无法导入"
        statusMessage = "已导入 \(imported.count) 个本地模块\(failureSuffix)"
        if !failures.isEmpty {
            presentedError = "部分本地模块无法导入：\n\(failures.joined(separator: "\n"))"
        }
    }

    func moduleOutputFolderOptions(preserving selected: String? = nil) -> [String] {
        var configuredFolders: [String] = []
        if settings.publishToLocal {
            configuredFolders.append(contentsOf: localModuleOutputFolders())
        }
        if settings.publishToGitHub {
            configuredFolders.append(contentsOf: githubModuleOutputFolders)
        }
        return ModuleOutputFolder.options(
            from: configuredFolders + settings.customModuleOutputFolders + modules.map(\.outputFolder),
            preserving: selected
        )
    }

    @discardableResult
    func createModuleOutputFolder(named rawValue: String) throws -> String {
        let folder = ModuleOutputFolder.normalized(rawValue)
        guard !folder.isEmpty else {
            throw RelayError.invalidOutput("请输入文件夹名称。")
        }

        if settings.publishToLocal {
            let rootPath = settings.localModuleDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rootPath.isEmpty else {
                throw RelayError.invalidOutput("请先设置本地模块根目录。")
            }
            let root = URL(filePath: rootPath, directoryHint: .isDirectory)
                .standardizedFileURL
            var destination = root
            for component in ModuleOutputFolder.components(folder) {
                destination = destination.appending(path: component, directoryHint: .isDirectory)
            }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }

        var folders = Set(settings.customModuleOutputFolders.map(ModuleOutputFolder.normalized))
        folders.insert(folder)
        settings.customModuleOutputFolders = ModuleOutputFolder.options(from: Array(folders))
            .filter { !$0.isEmpty }
        if !githubModuleOutputFolders.contains(folder) {
            githubModuleOutputFolders = ModuleOutputFolder.options(from: githubModuleOutputFolders + [folder])
        }
        saveSettings()
        statusMessage = settings.publishToLocal
            ? "已创建/记录文件夹 \(folder)"
            : "已添加 GitHub 文件夹 \(folder)，发布模块时会自动创建路径"
        return folder
    }

    func refreshModuleOutputFolders(force: Bool = false) async {
        guard settings.publishToGitHub, settings.github.isConfigured else {
            githubModuleOutputFolders = [ModuleOutputFolder.root]
            githubModuleOutputFoldersLastRefreshedAt = nil
            githubModuleOutputFoldersConfiguration = nil
            return
        }
        let now = Date.now
        if !force,
           githubModuleOutputFoldersConfiguration == settings.github,
           let lastRefresh = githubModuleOutputFoldersLastRefreshedAt,
           now.timeIntervalSince(lastRefresh) < 300 {
            return
        }
        do {
            let token = githubTokenStorageStatus == .notChecked ? "" : githubToken
            let folders = try await githubClient.listDirectories(settings: settings.github, token: token)
            githubModuleOutputFolders = ModuleOutputFolder.options(
                from: folders + modules.map(\.outputFolder)
            )
            githubModuleOutputFoldersLastRefreshedAt = now
            githubModuleOutputFoldersConfiguration = settings.github
        } catch {
            githubModuleOutputFolders = ModuleOutputFolder.options(from: modules.map(\.outputFolder))
            githubModuleOutputFoldersLastRefreshedAt = now
            githubModuleOutputFoldersConfiguration = settings.github
        }
    }

    func openConfigurationDirectory() {
        NSWorkspace.shared.open(PersistenceStore.configurationDirectoryURL)
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

    func addModule(from draft: ModuleDraft) throws {
        if let message = draft.validationMessage { throw RelayError.invalidOutput(message) }
        let source = draft.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = draft.category.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputFolder = ModuleOutputFolder.normalized(draft.outputFolder)
        let customIconURL = draft.normalizedCustomIconURL
        guard !modules.contains(where: { ModuleSourceIdentity.matches($0.effectiveOriginalSourceURL, source) }) else {
            throw RelayError.duplicateSourceURL
        }
        let outputFileName = ModuleNamingPlanner.uniqueOutputFileName(
            for: draft,
            source: source,
            modules: modules,
            combinedModuleFileName: settings.combinedModuleFileName
        )
        let localStorageRelativePath = try ModuleNamingPlanner.localStorageRelativePath(
            storageLocation: draft.storageLocation,
            source: source,
            outputFileName: outputFileName,
            outputFolder: outputFolder,
            localModuleDirectory: settings.localModuleDirectory
        )
        let module = RelayModule(
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceURL: source,
            sourceFormat: draft.sourceFormat,
            outputFileName: outputFileName,
            category: category,
            outputFolder: outputFolder,
            storageLocation: draft.storageLocation,
            localStorageRelativePath: localStorageRelativePath,
            preservesOutputFileName: draft.storageLocation == .local,
            publishesStandalone: draft.publishesStandalone,
            isEnabled: draft.isEnabled,
            scriptHubOptions: draft.scriptHubOptions,
            iconURL: customIconURL,
            customIconURL: customIconURL,
            detectedSourceFormat: ModuleNamingPlanner.detectedFormat(for: draft.sourceFormat, source: source)
        )
        registerLocalChange()
        modules.append(module)
        selectedModuleID = module.id
        if let customIconURL, let url = URL(string: customIconURL) {
            Task { try? await iconStore.cacheIcon(from: url, for: module.id, force: true) }
        }
        try persistModules()
        statusMessage = "已添加 \(module.name)，即将自动更新"
        scheduleAutomaticUpdate()
    }

    func updateModule(id: UUID, from draft: ModuleDraft) throws {
        if let message = draft.validationMessage { throw RelayError.invalidOutput(message) }
        guard let index = modules.firstIndex(where: { $0.id == id }) else { return }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = draft.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = draft.category.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputFolder = ModuleOutputFolder.normalized(draft.outputFolder)
        let customIconURL = draft.normalizedCustomIconURL
        guard !modules.contains(where: {
            $0.id != id && ModuleSourceIdentity.matches($0.effectiveOriginalSourceURL, source)
        }) else {
            throw RelayError.duplicateSourceURL
        }
        let outputFileName = ModuleNamingPlanner.uniqueOutputFileName(
            for: draft,
            source: source,
            modules: modules,
            combinedModuleFileName: settings.combinedModuleFileName,
            excluding: id
        )
        let detectedSourceFormat = ModuleNamingPlanner.detectedFormat(for: draft.sourceFormat, source: source)
        let localStorageRelativePath = try ModuleNamingPlanner.localStorageRelativePath(
            storageLocation: draft.storageLocation,
            source: source,
            outputFileName: outputFileName,
            outputFolder: outputFolder,
            localModuleDirectory: settings.localModuleDirectory
        )
        let current = modules[index]
        guard current.name != name ||
                current.sourceURL != source ||
                current.sourceFormat != draft.sourceFormat ||
                current.outputFileName != outputFileName ||
                current.category != category ||
                current.outputFolder != outputFolder ||
                current.storageLocation != draft.storageLocation ||
                current.localStorageRelativePath != localStorageRelativePath ||
                current.preservesOutputFileName != (draft.storageLocation == .local) ||
                current.publishesStandalone != draft.publishesStandalone ||
                current.isEnabled != draft.isEnabled ||
                current.scriptHubOptions != draft.scriptHubOptions ||
                current.customIconURL != customIconURL else {
            statusMessage = "没有需要保存的更改"
            return
        }
        registerLocalChange()
        let sourceChanged = modules[index].sourceURL != source ||
            modules[index].sourceFormat != draft.sourceFormat ||
            modules[index].scriptHubOptions != draft.scriptHubOptions
        let customIconChanged = modules[index].customIconURL != customIconURL
        let previousOutputFileName = modules[index].outputFileName
        modules[index].name = name
        modules[index].sourceURL = source
        modules[index].sourceFormat = draft.sourceFormat
        modules[index].outputFileName = outputFileName
        modules[index].category = category
        modules[index].outputFolder = outputFolder
        modules[index].storageLocation = draft.storageLocation
        modules[index].localStorageRelativePath = localStorageRelativePath
        modules[index].preservesOutputFileName = draft.storageLocation == .local
        modules[index].publishesStandalone = draft.publishesStandalone
        modules[index].isEnabled = draft.isEnabled
        modules[index].scriptHubOptions = draft.scriptHubOptions
        modules[index].customIconURL = customIconURL
        modules[index].detectedSourceFormat = detectedSourceFormat
        if sourceChanged {
            modules[index].state = .never
            modules[index].lastError = nil
            modules[index].sourceETag = nil
            modules[index].sourceLastModified = nil
            modules[index].sourceContentHash = nil
            modules[index].sourceCheckedAt = nil
            modules[index].conversionEngineRevision = nil
            modules[index].scriptHubSubscription = nil
        }
        if sourceChanged || customIconChanged {
            if let customIconURL, let url = URL(string: customIconURL) {
                modules[index].iconURL = customIconURL
                Task { try? await iconStore.cacheIcon(from: url, for: id, force: true) }
            } else {
                modules[index].iconURL = nil
                Task { try? await iconStore.removeIcon(for: id) }
            }
        }
        _ = previousOutputFileName
        try persistModules()
        statusMessage = sourceChanged
            ? "已保存 \(modules[index].name)，即将自动更新"
            : "已保存 \(modules[index].name)，正在刷新输出"
        if sourceChanged, shouldUpdateModule(modules[index]) {
            scheduleAutomaticUpdate()
        } else {
            Task { await rebuildCombinedFromCache() }
        }
        if customIconChanged, customIconURL == nil, !sourceChanged {
            Task { await refreshModuleMetadataFromCache() }
        }
    }

    func setModuleEnabled(id: UUID, enabled: Bool) {
        guard let index = modules.firstIndex(where: { $0.id == id }) else { return }
        guard modules[index].isEnabled != enabled else { return }
        registerLocalChange()
        modules[index].isEnabled = enabled
        try? persistModules()
        if settings.combinedModuleEnabled {
            statusMessage = enabled ? "已将 \(modules[index].name) 加入总模块" : "已将 \(modules[index].name) 从总模块移除"
        } else {
            statusMessage = enabled ? "已记录 \(modules[index].name) 将在开启总模块后加入" : "已记录 \(modules[index].name) 不加入总模块"
        }
        if enabled, shouldUpdateModule(modules[index]) {
            scheduleAutomaticUpdate()
        } else {
            Task { await rebuildCombinedFromCache() }
        }
    }

    func moveModules(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let reordered = ModuleOrdering.moving(modules, fromOffsets: offsets, toOffset: destination)
        guard reordered != modules else { return }
        registerLocalChange()
        modules = reordered
        do {
            try persistModules()
            statusMessage = "已调整模块优先级，正在刷新输出"
            Task { await rebuildCombinedFromCache() }
        } catch {
            presentedError = "保存模块顺序失败：\(error.localizedDescription)"
        }
    }

    func reorderModules(ids: [UUID]) {
        guard ids.count == modules.count,
              Set(ids) == Set(modules.map(\.id)) else { return }
        let lookup = Dictionary(uniqueKeysWithValues: modules.map { ($0.id, $0) })
        let reordered = ids.compactMap { lookup[$0] }
        guard reordered != modules else { return }
        registerLocalChange()
        modules = reordered
        do {
            try persistModules()
            statusMessage = "已调整模块优先级，正在刷新输出"
            Task { await rebuildCombinedFromCache() }
        } catch {
            presentedError = "保存模块顺序失败：\(error.localizedDescription)"
        }
    }

    func deleteModule(id: UUID) async {
        guard let index = modules.firstIndex(where: { $0.id == id }) else { return }
        registerLocalChange()
        let module = modules.remove(at: index)
        try? await fileStore.removeComponent(id: id)
        try? await fileStore.removeAssets(id: id)
        try? await iconStore.removeIcon(for: id)
        try? persistModules()
        selectedModuleID = modules.first?.id
        await rebuildCombinedFromCache()
        statusMessage = "已删除 \(module.name)，输出已刷新"
    }

    func updateAll() async {
        let admission = updateAdmission
        guard admission.isAccepted else {
            statusMessage = admission.message
            return
        }
        let updateModules = modules.filter(shouldUpdateModule)
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
                                module.sourceETag = snapshot.etag
                                module.sourceLastModified = snapshot.lastModified
                                module.sourceContentHash = snapshot.contentHash
                                module.sourceCheckedAt = snapshot.checkedAt
                                module.state = .current
                                module.lastError = nil
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
                                    message: "来源内容没有变化"
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
                if let revisionSnapshot {
                    module.sourceETag = revisionSnapshot.etag
                    module.sourceLastModified = revisionSnapshot.lastModified
                    module.sourceContentHash = revisionSnapshot.contentHash
                    module.sourceCheckedAt = revisionSnapshot.checkedAt
                } else {
                    module.sourceCheckedAt = .now
                }
                module.conversionEngineRevision = nativeModule ? nil : upstreamState.revision
                let convertedContent = try await fileStore.readConvertedComponent(id: module.id)
                if await fileStore.hasOverride(id: module.id),
                   let baseHash = module.overrideBaseHash {
                    module.hasOverrideConflict = baseHash != Data(convertedContent.utf8).sha256String
                } else {
                    module.hasOverrideConflict = false
                }
                let detectedIcon = await processingWorker.iconURL(
                    in: effectiveContent,
                    relativeTo: module.sourceURL
                )
                if let subscription = ModuleMetadataParser.scriptHubSubscription(in: effectiveContent) {
                    _ = module.applyScriptHubSubscriptionMetadata(subscription)
                }
                let preferredIcon = module.customIconURL.flatMap(URL.init(string:)) ?? detectedIcon
                module.iconURL = preferredIcon?.absoluteString
                module.detectedSourceFormat = ModuleNamingPlanner.detectedFormat(
                    for: module.sourceFormat,
                    source: module.sourceURL
                )
                if let preferredIcon {
                    try? await iconStore.cacheIcon(from: preferredIcon, for: module.id, force: true)
                } else {
                    try? await iconStore.removeIcon(for: module.id)
                }
                let nextContentHash = await processingWorker.contentFingerprint(
                    of: effectiveContent,
                    assets: result.assets
                )
                let moduleContentChanged = module.contentHash != nextContentHash
                if moduleContentChanged { contentChanged = true }
                module.contentHash = nextContentHash
                module.lastUpdatedAt = .now
                module.state = .current
                module.lastError = nil
                replace(module)
                newHistory.append(UpdateHistoryEntry(
                    moduleID: module.id,
                    moduleName: module.name,
                    outcome: .updated,
                    duration: Date.now.timeIntervalSince(startedAt),
                    message: module.hasOverrideConflict ? "上游已更新，本地编辑需要确认" : "转换完成",
                    contentChanged: moduleContentChanged
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
                let failureMessage = updateFailureMessage(
                    for: error,
                    module: module,
                    sourceCheckFailure: sourceFailure
                )
                setState(id: module.id, state: .failed, error: failureMessage)
                if let cached = try? await fileStore.readComponent(id: module.id) {
                    let current = modules.first(where: { $0.id == module.id }) ?? module
                    let materialized = await processingWorker.materialize(
                        cached,
                        overrides: current.argumentOverrides
                    )
                    if shouldContributeToCombined(current) {
                        components.append((current, materialized))
                    }
                    newHistory.append(UpdateHistoryEntry(
                        moduleID: module.id,
                        moduleName: module.name,
                        outcome: .cachedAfterFailure,
                        duration: Date.now.timeIntervalSince(startedAt),
                        message: failureMessage,
                        usedCache: true
                    ))
                } else {
                    if shouldContributeToCombined(module) {
                        missingCache.append(module.name)
                        missingCacheDetails.append(missingCacheFailureDetail(
                            moduleName: module.name,
                            failureMessage: failureMessage
                        ))
                    }
                    newHistory.append(UpdateHistoryEntry(
                        moduleID: module.id,
                        moduleName: module.name,
                        outcome: .failed,
                        duration: Date.now.timeIntervalSince(startedAt),
                        message: failureMessage
                    ))
                }
            }
            synchronizationCompletedCount += 1
            await Task.yield()
        }
        recordHistory(newHistory)
        try? persistModules()

        guard shouldContinueCurrentWork(generation: updateGeneration) else { return }

        guard missingCache.isEmpty else {
            statusMessage = "无法重建总模块：\(missingCache.joined(separator: "、")) 尚无可用缓存"
            let details = missingCacheDetails.isEmpty ? missingCache.joined(separator: "\n") : missingCacheDetails.joined(separator: "\n")
            presentedError = "以下来源首次转换失败，因此没有覆盖当前总模块：\n\(details)"
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
            if settings.publishToGitHub, settings.automaticallyPublish, settings.github.isConfigured,
               !ensureGitHubTokenLoaded(showStatusMessage: false).isEmpty {
                let automaticPublishPlan = githubPublishPlan
                if AutomaticPublishPlanner.shouldRunScheduledPublish(plan: automaticPublishPlan) {
                    if AutomaticPublishPlanner.shouldQueueAfterModuleUpdate(
                        plan: automaticPublishPlan,
                        contentChanged: contentChanged
                    ) {
                        scheduleAutomaticPublish()
                    }
                    statusMessage = UpdateCompletionStatusPlanner.automaticPublishQueuedStatus(
                        contentChanged: contentChanged,
                        failures: failures
                    )
                } else {
                    clearAutomaticPublishSchedule()
                    statusMessage = AutomaticPublishPlanner.skippedAfterModuleUpdateStatus(
                        contentChanged: contentChanged,
                        failures: failures
                    )
                }
            } else if pendingPublishPreview?.destination == .local {
                statusMessage = UpdateCompletionStatusPlanner.localCleanupPendingStatus(
                    failures: failures,
                    staleFileCount: pendingPublishPreview?.deletedFiles.count ?? 0
                )
            } else {
                statusMessage = UpdateCompletionStatusPlanner.refreshedOutputStatus(
                    combinedModuleEnabled: settings.combinedModuleEnabled,
                    combinedSourceCount: components.count,
                    failures: failures
                )
            }
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

    private func scheduleAutomaticUpdate() {
        automaticUpdateTask?.cancel()
        automaticUpdateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self else { return }
            while self.isWorking, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            await self.updateAll()
        }
    }

    private func scheduleAutomaticPublish() {
        guard settings.publishToGitHub, settings.automaticallyPublish, settings.github.isConfigured else { return }
        guard !ensureGitHubTokenLoaded(showStatusMessage: false).isEmpty else { return }
        guard AutomaticPublishPlanner.shouldRunScheduledPublish(plan: githubPublishPlan) else {
            clearAutomaticPublishSchedule()
            return
        }
        automaticPublishTask?.cancel()
        let scheduledAt = Date.now
        automaticPublishScheduledAt = scheduledAt
        automaticPublishRunsAt = scheduledAt.addingTimeInterval(TimeInterval(Self.automaticPublishDelaySeconds))
        automaticPublishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.automaticPublishDelaySeconds))
            guard !Task.isCancelled, let self else { return }
            while self.isWorking, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled,
                  self.settings.publishToGitHub,
                  self.settings.automaticallyPublish,
                  self.settings.github.isConfigured else {
                self.clearAutomaticPublishSchedule()
                return
            }
            guard !self.ensureGitHubTokenLoaded(showStatusMessage: false).isEmpty else {
                self.clearAutomaticPublishSchedule()
                return
            }
            guard AutomaticPublishPlanner.shouldRunScheduledPublish(plan: self.githubPublishPlan) else {
                self.clearAutomaticPublishSchedule()
                self.statusMessage = AutomaticPublishPlanner.noStandaloneModulesStatus
                return
            }
            guard await self.hasGitHubAutomaticPublishableFiles() else {
                self.clearAutomaticPublishSchedule()
                self.statusMessage = AutomaticPublishPlanner.noStandaloneFilesStatus
                return
            }
            self.clearAutomaticPublishSchedule()
            self.beginWork(.automaticPublishing)
            defer {
                self.endWork(.automaticPublishing)
                self.automaticPublishTask = nil
            }
            do {
                guard self.shouldContinueCurrentWork() else { return }
                let preview = try await self.githubPublishPreview()
                guard self.shouldContinueCurrentWork() else { return }
                if preview.requiresDeletionConfirmation {
                    self.pendingPublishPreview = preview
                    self.statusMessage = "GitHub 发布需要确认删除 \(preview.deletedFiles.count) 个旧文件"
                    return
                }
                let report = try await self.publishAllInternal()
                guard self.shouldContinueCurrentWork() else { return }
                self.statusMessage = report.changedFileCount == 0
                    ? "GitHub 内容没有变化，无需上传"
                    : "\(self.githubPublishRetryPrefix(report))已合并发布到 GitHub（\(report.changedFileCount) 个文件变更）"
                self.recordGitHubPublish(report)
            } catch {
                guard !self.isCurrentWorkCancellation(error) else { return }
                if self.isNoFilesToPublish(error) {
                    self.statusMessage = AutomaticPublishPlanner.noStandaloneFilesStatus
                    return
                }
                self.presentedError = "GitHub 自动发布失败：\(error.localizedDescription)"
            }
        }
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

    func publishAll() async {
        guard !isWorking else { return }
        cancelAutomaticPublishSchedule()
        beginWork(.publishing)
        defer { endWork(.publishing) }
        do {
            let preview = try await githubPublishPreview()
            guard shouldContinueCurrentWork() else { return }
            if preview.requiresDeletionConfirmation {
                pendingPublishPreview = preview
                statusMessage = "发布前需要确认删除 \(preview.deletedFiles.count) 个旧文件"
                return
            }
            let report = try await publishAllInternal()
            guard shouldContinueCurrentWork() else { return }
            statusMessage = report.changedFileCount == 0
                ? "没有文件需要发布"
                : githubPublishSuccessMessage(report)
            recordGitHubPublish(report)
        } catch {
            if isCurrentWorkCancellation(error) { return }
            if isNoFilesToPublish(error) {
                statusMessage = "没有可发布的模块文件"
                return
            }
            presentedError = error.localizedDescription
        }
    }

    func publishModules(moduleIDs: Set<UUID>) async -> Bool {
        guard !isWorking else { return false }
        guard settings.publishToGitHub else {
            statusMessage = "GitHub 发布未开启"
            return false
        }
        guard !moduleIDs.isEmpty else {
            statusMessage = "请选择要发布的模块"
            return false
        }
        cancelAutomaticPublishSchedule()
        beginWork(.publishing)
        defer { endWork(.publishing) }
        do {
            let report = try await publishSelectedModulesInternal(moduleIDs: moduleIDs)
            guard shouldContinueCurrentWork() else { return false }
            statusMessage = report.changedFileCount == 0
                ? "所选模块没有文件需要发布"
                : "\(githubPublishRetryPrefix(report))已发布所选模块到 GitHub（\(report.changedFileCount) 个文件变更）"
            recordGitHubPublish(report)
            return true
        } catch {
            if isCurrentWorkCancellation(error) { return false }
            if isNoFilesToPublish(error) {
                statusMessage = "所选模块没有可发布的独立输出"
                return false
            }
            presentedError = error.localizedDescription
            return false
        }
    }

    func previewPublish() async {
        guard !isWorking else { return }
        guard settings.publishToGitHub else {
            statusMessage = "GitHub 发布未开启；本地发布会在合并时自动生成清理预览"
            return
        }
        cancelAutomaticPublishSchedule()
        beginWork(.previewingPublish)
        defer { endWork(.previewingPublish) }
        do {
            let preview = try await githubPublishPreview()
            guard shouldContinueCurrentWork() else { return }
            pendingPublishPreview = preview
            statusMessage = preview.hasChanges
                ? "已生成 GitHub 发布预览（\(preview.changedFileCount) 个文件变更）"
                : "GitHub 内容没有变化"
        } catch {
            if isCurrentWorkCancellation(error) { return }
            if isNoFilesToPublish(error) {
                statusMessage = "没有可发布的模块文件，已跳过 GitHub 发布预览"
                return
            }
            presentedError = error.localizedDescription
        }
    }

    func confirmPendingPublish() async {
        guard let preview = pendingPublishPreview, !isWorking else { return }
        beginWork(.confirmingPublish)
        defer { endWork(.confirmingPublish) }
        do {
            switch preview.destination {
            case .gitHub:
                let report = try await publishAllInternal(allowDeleting: true)
                guard shouldContinueCurrentWork() else { return }
                pendingPublishPreview = nil
                statusMessage = report.changedFileCount == 0
                    ? "没有文件需要发布"
                    : githubPublishSuccessMessage(report)
                recordGitHubPublish(report)
            case .local:
                try enterNonCancellableWorkPhase(
                    statusMessage: "正在清理本地旧文件，已进入不可取消阶段…"
                )
                _ = try await fileStore.exportPublishedFiles(
                    [],
                    toRootDirectory: preview.targetDescription,
                    removingObsoleteRelativePaths: preview.deletedFiles,
                    knownManagedRelativePaths: settings.localPublishedRootDirectory == preview.targetDescription
                        ? settings.localPublishedFilePaths
                        : []
                )
                settings.localPublishedRootDirectory = preview.targetDescription
                settings.localPublishedFilePaths = preview.activeFiles
                pendingPublishPreview = nil
                saveSettings()
                statusMessage = "已清理 \(preview.deletedFiles.count) 个本地旧文件"
            }
        } catch {
            if isCurrentWorkCancellation(error) { return }
            if isNoFilesToPublish(error) {
                pendingPublishPreview = nil
                statusMessage = "没有可发布的模块文件"
                return
            }
            presentedError = error.localizedDescription
        }
    }

    func dismissPendingPublishPreview() {
        pendingPublishPreview = nil
        statusMessage = "已取消发布预览"
    }

    private func githubPublishPreview() async throws -> PublishPreview {
        try checkCurrentWorkCancellation()
        try Task.checkCancellation()
        guard hasGitHubPublishableModuleSelection else { throw RelayError.noFilesToPublish }
        let token = ensureGitHubTokenLoaded(showStatusMessage: false)
        guard !token.isEmpty else { throw RelayError.githubTokenMissing }
        let isPrivate = try await githubClient.test(settings: settings.github, token: token)
        try checkCurrentWorkCancellation()
        try Task.checkCancellation()
        if settings.github.repositoryIsPrivate != isPrivate {
            settings.github.repositoryIsPrivate = isPrivate
            saveSettings()
        }
        let data = settings.combinedModuleEnabled ? try await fileStore.readCombined() : nil
        try checkCurrentWorkCancellation()
        let files = try await currentPublishedFiles(combinedData: data, includeAssets: true, destination: .gitHub)
        try checkCurrentWorkCancellation()
        guard !files.isEmpty else { throw RelayError.noFilesToPublish }
        let currentPaths = files.map(\.name)
        let repositoryKey = githubPublishRepositoryKey(settings.github)
        let stalePaths = settings.githubPublishedRepositoryKey == repositoryKey
            ? settings.githubPublishedFilePaths.filter { !currentPaths.contains($0) }
            : []
        let report = try await githubClient.previewPublish(
            files: files,
            deleting: stalePaths,
            settings: settings.github,
            token: token
        )
        return PublishPreview(
            destination: .gitHub,
            targetDescription: "\(settings.github.owner)/\(settings.github.repository)@\(settings.github.branch)/\(settings.github.directory)",
            activeFiles: currentPaths,
            changedFiles: report.publishedFiles,
            deletedFiles: report.deletedFiles
        )
    }

    private func publishAllInternal(allowDeleting: Bool = true) async throws -> PublishReport {
        try checkCurrentWorkCancellation()
        try Task.checkCancellation()
        guard hasGitHubPublishableModuleSelection else { throw RelayError.noFilesToPublish }
        let token = ensureGitHubTokenLoaded(showStatusMessage: false)
        guard !token.isEmpty else { throw RelayError.githubTokenMissing }
        let isPrivate = try await githubClient.test(settings: settings.github, token: token)
        try checkCurrentWorkCancellation()
        try Task.checkCancellation()
        if settings.github.repositoryIsPrivate != isPrivate {
            settings.github.repositoryIsPrivate = isPrivate
            saveSettings()
        }
        let data = settings.combinedModuleEnabled ? try await fileStore.readCombined() : nil
        try checkCurrentWorkCancellation()
        let files = try await currentPublishedFiles(combinedData: data, includeAssets: true, destination: .gitHub)
        try checkCurrentWorkCancellation()
        guard !files.isEmpty else { throw RelayError.noFilesToPublish }
        let currentPaths = files.map(\.name)
        let repositoryKey = githubPublishRepositoryKey(settings.github)
        let staleCandidates = settings.githubPublishedRepositoryKey == repositoryKey
            ? settings.githubPublishedFilePaths.filter { !currentPaths.contains($0) }
            : []
        let stalePaths = allowDeleting ? staleCandidates : []
        try enterNonCancellableWorkPhase(
            statusMessage: "正在提交 GitHub 发布，已进入不可取消阶段…"
        )
        let report = try await githubClient.publish(
            files: files,
            deleting: stalePaths,
            settings: settings.github,
            token: token
        )
        if staleCandidates.isEmpty || allowDeleting {
            settings.githubPublishedRepositoryKey = repositoryKey
            settings.githubPublishedFilePaths = currentPaths
            saveSettings()
        }
        return report
    }

    private func publishSelectedModulesInternal(moduleIDs: Set<UUID>) async throws -> PublishReport {
        try checkCurrentWorkCancellation()
        try Task.checkCancellation()
        let plan = PublishCoordinator.selectedPlan(modules: modules, moduleIDs: moduleIDs)
        guard plan.hasPublishableModuleSelection else { throw RelayError.noFilesToPublish }
        let token = ensureGitHubTokenLoaded(showStatusMessage: false)
        guard !token.isEmpty else { throw RelayError.githubTokenMissing }
        let isPrivate = try await githubClient.test(settings: settings.github, token: token)
        try checkCurrentWorkCancellation()
        try Task.checkCancellation()
        if settings.github.repositoryIsPrivate != isPrivate {
            settings.github.repositoryIsPrivate = isPrivate
            saveSettings()
        }
        let files = try await selectedPublishedFiles(plan: plan)
        guard !files.isEmpty else { throw RelayError.noFilesToPublish }
        let currentPaths = files.map(\.name)
        try enterNonCancellableWorkPhase(
            statusMessage: "正在提交所选模块，已进入不可取消阶段…"
        )
        let report = try await githubClient.publish(
            files: files,
            deleting: [],
            settings: settings.github,
            token: token
        )
        let repositoryKey = githubPublishRepositoryKey(settings.github)
        let knownPaths = settings.githubPublishedRepositoryKey == repositoryKey
            ? settings.githubPublishedFilePaths
            : []
        settings.githubPublishedRepositoryKey = repositoryKey
        settings.githubPublishedFilePaths = Array(Set(knownPaths).union(currentPaths)).sorted()
        saveSettings()
        return report
    }

    private func rebuildCombinedFromCache() async {
        let rebuildGeneration = localChangeGeneration
        let enabled = settings.combinedModuleEnabled ? modules.filter(\.isEnabled) : []
        guard !enabled.isEmpty else {
            try? await fileStore.removeCombined()
            try? await publishCurrentFiles(combinedData: nil, includeAssets: false)
            scheduleAutomaticPublish()
            return
        }
        var components: [(RelayModule, String)] = []
        for module in enabled {
            guard let content = try? await fileStore.readComponent(id: module.id) else { return }
            let materialized = await processingWorker.materialize(
                content,
                overrides: module.argumentOverrides
            )
            components.append((module, materialized))
        }
        do {
            try await writeCombinedModule(components)
            guard rebuildGeneration == localChangeGeneration else {
                await rebuildCombinedFromCache()
                return
            }
            scheduleAutomaticPublish()
        } catch {
            presentedError = "自动合并失败：\(error.localizedDescription)"
        }
    }

    private func refreshModuleMetadataFromCache() async {
        var changed = false
        for moduleValue in modules {
            guard let content = try? await fileStore.readComponent(id: moduleValue.id) else { continue }
            var module = moduleValue
            var moduleChanged = false
            if await fileStore.hasOverride(id: module.id), module.overrideBaseHash == nil,
               let converted = try? await fileStore.readConvertedComponent(id: module.id) {
                module.overrideBaseHash = Data(converted.utf8).sha256String
                moduleChanged = true
            }
            if let subscription = ModuleMetadataParser.scriptHubSubscription(in: content) {
                moduleChanged = module.applyScriptHubSubscriptionMetadata(subscription) || moduleChanged
            }
            let detectedIcon = await processingWorker.iconURL(in: content, relativeTo: module.sourceURL)
            let preferredIcon = module.customIconURL.flatMap(URL.init(string:)) ?? detectedIcon
            let value = preferredIcon?.absoluteString
            let iconChanged = module.iconURL != value
            if iconChanged {
                module.iconURL = value
            }
            let resolvedFormat = ModuleNamingPlanner.detectedFormat(
                for: module.sourceFormat,
                source: module.sourceURL
            )
            let formatChanged = module.detectedSourceFormat != resolvedFormat
            if formatChanged { module.detectedSourceFormat = resolvedFormat }
            moduleChanged = moduleChanged || iconChanged || formatChanged
            if moduleChanged {
                replace(module)
                changed = true
            }
            if let preferredIcon {
                try? await iconStore.cacheIcon(from: preferredIcon, for: module.id, force: iconChanged)
            } else {
                try? await iconStore.removeIcon(for: module.id)
            }
        }
        if changed { try? persistModules() }
    }

    private func currentPublishedFiles(
        combinedData: Data?,
        includeAssets: Bool,
        destination: PublishDestination
    ) async throws -> [PublishFile] {
        try await publishedFiles(
            plan: githubPublishPlan,
            combinedData: combinedData,
            includeAssets: includeAssets,
            destination: destination
        )
    }

    private func selectedPublishedFiles(plan: PublishPlan) async throws -> [PublishFile] {
        try await publishedFiles(
            plan: plan,
            combinedData: nil,
            includeAssets: true,
            destination: .gitHub
        )
    }

    private func publishedFiles(
        plan: PublishPlan,
        combinedData: Data?,
        includeAssets: Bool,
        destination: PublishDestination
    ) async throws -> [PublishFile] {
        try await PublishFileAssembler.files(
            request: PublishFileAssemblyRequest(
                plan: plan,
                combinedData: combinedData,
                combinedFileName: settings.combinedModuleFileName,
                includeAssets: includeAssets,
                destination: destination,
                localModuleDirectory: settings.localModuleDirectory
            ),
            readComponent: { [fileStore] id in
                try? await fileStore.readComponent(id: id)
            },
            generatedAssetFiles: { [fileStore] ids in
                try await fileStore.generatedAssetFiles(for: ids)
            },
            materialize: { [processingWorker] content, overrides in
                await processingWorker.materialize(content, overrides: overrides)
            },
            applyingModuleMetadata: { [processingWorker] name, category, content in
                await processingWorker.applyingModuleMetadata(
                    name: name,
                    category: category,
                    to: content
                )
            },
            cancellationCheckpoint: {
                try checkCurrentWorkCancellation()
                try Task.checkCancellation()
            }
        )
    }

    private func writeCombinedModule(_ components: [(RelayModule, String)]) async throws {
        let merged = try await processingWorker.merge(
            components,
            engineRevision: upstreamState.revision
        )
        try await fileStore.writeCombined(merged)
        try await publishCurrentFiles(combinedData: Data(merged.utf8), includeAssets: false)
    }

    private func publishCurrentFiles(combinedData: Data?, includeAssets: Bool) async throws {
        if settings.publishToLocal {
            let files = try await currentPublishedFiles(
                combinedData: combinedData,
                includeAssets: includeAssets,
                destination: .local
            )
            let currentPaths = files.map(\.name)
            let knownManagedPaths = settings.localPublishedRootDirectory == settings.localModuleDirectory
                ? settings.localPublishedFilePaths
                : []
            let stalePaths = settings.localPublishedRootDirectory == settings.localModuleDirectory
                ? settings.localPublishedFilePaths.filter { !currentPaths.contains($0) }
                : []
            _ = try await fileStore.exportPublishedFiles(
                files,
                toRootDirectory: settings.localModuleDirectory,
                removingObsoleteRelativePaths: [],
                knownManagedRelativePaths: knownManagedPaths
            )
            if stalePaths.isEmpty {
                settings.localPublishedRootDirectory = settings.localModuleDirectory
                settings.localPublishedFilePaths = currentPaths
                if pendingPublishPreview?.destination == .local {
                    pendingPublishPreview = nil
                }
                saveSettings()
            } else {
                pendingPublishPreview = PublishPreview(
                    destination: .local,
                    targetDescription: settings.localModuleDirectory,
                    activeFiles: currentPaths,
                    changedFiles: [],
                    deletedFiles: stalePaths
                )
                statusMessage = "已写入本地模块，等待确认清理 \(stalePaths.count) 个旧文件"
            }
        }
    }

    private func cleanupLegacyOutputFiles() async {
        let paths = legacyPublishedRelativePaths()
        for directory in legacyOutputCleanupDirectories() {
            _ = try? await fileStore.removeLegacyPublishedFiles(in: directory, relativePaths: paths)
        }
    }

    private func githubPublishSuccessMessage(_ report: PublishReport) -> String {
        let scope = githubPublishPlan.scopeTitle
        return "\(githubPublishRetryPrefix(report))\(scope)已发布到 GitHub（\(report.changedFileCount) 个文件变更）"
    }

    private func legacyOutputCleanupDirectories() -> [String] {
        LegacyOutputCleanupPlanner.cleanupDirectories(
            outputDirectory: settings.outputDirectory,
            configurationDirectory: configurationDirectoryPath,
            localModuleDirectory: settings.localModuleDirectory
        )
    }

    private func legacyPublishedRelativePaths() -> [String] {
        LegacyOutputCleanupPlanner.publishedRelativePaths(
            combinedModuleFileName: settings.combinedModuleFileName,
            managedEngineFileName: settings.managedEngineFileName
        )
    }

    var combinedRawURL: URL? {
        guard settings.combinedModuleEnabled else { return nil }
        return settings.publishedURL(for: FilenameSanitizer.sgmoduleName(from: settings.combinedModuleFileName))
    }

    var combinedLocalFileURL: URL? {
        settings.localCombinedModuleURL
    }

    var latestGitHubPublish: GitHubPublishSnapshot? {
        GitHubPublishSnapshot.latest(in: updateHistory, settings: settings.github)
    }

    var webManagementURL: URL? {
        WebManagementController.url(settings: settings, accessToken: webAccessToken, includingToken: true)
    }

    var webManagementDisplayURL: URL? {
        WebManagementController.url(settings: settings, accessToken: webAccessToken, includingToken: false)
    }

    var webManagementAccessModeTitle: String {
        WebManagementController.accessModeTitle(settings: settings)
    }

    private var webManagementHost: String {
        WebManagementController.host(settings: settings)
    }

    func rawURL(for module: RelayModule) -> URL? {
        guard module.publishesStandalone else { return nil }
        return settings.publishedURL(for: module.publishedRelativePath)
    }

    func previewContent(for module: RelayModule) async throws -> String {
        try await modulePreviewProvider.previewContent(for: module)
    }

    func moduleArgumentInfo(for module: RelayModule) async -> ModuleArgumentInfo {
        await modulePreviewProvider.moduleArgumentInfo(for: module)
    }

    func setModuleArgument(moduleID: UUID, key: String, value: String, defaultValue: String) {
        guard let index = modules.firstIndex(where: { $0.id == moduleID }) else { return }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = modules[index].argumentOverrides[key]
        let nextStored: String? = normalized == defaultValue ? nil : normalized
        guard stored != nextStored else { return }
        registerLocalChange()
        if let nextStored {
            modules[index].argumentOverrides[key] = nextStored
        } else {
            modules[index].argumentOverrides.removeValue(forKey: key)
        }
        try? persistModules()
        statusMessage = "已更新 \(modules[index].name) 的模块参数"
        Task { await rebuildCombinedFromCache() }
    }

    func resetModuleArguments(moduleID: UUID) {
        guard let index = modules.firstIndex(where: { $0.id == moduleID }),
              !modules[index].argumentOverrides.isEmpty else { return }
        registerLocalChange()
        modules[index].argumentOverrides.removeAll()
        try? persistModules()
        statusMessage = "已恢复 \(modules[index].name) 的默认参数"
        Task { await rebuildCombinedFromCache() }
    }

    func combinedPreviewContent() async throws -> String {
        try await modulePreviewProvider.combinedPreviewContent(
            combinedModuleEnabled: settings.combinedModuleEnabled
        )
    }

    func savePreviewContent(_ content: String, for module: RelayModule) async throws {
        guard !isWorking else { throw RelayError.invalidOutput("当前正在更新，请稍后再写入。") }
        let namedContent = await processingWorker.applyingModuleMetadata(
            name: module.name,
            category: module.category,
            to: content
        )
        if let current = try? await modulePreviewProvider.componentContent(for: module),
           current == namedContent {
            statusMessage = "内容没有变化"
            return
        }
        beginWork(.savingPreview)
        defer { endWork(.savingPreview) }
        registerLocalChange()
        try await fileStore.writeComponentOverride(namedContent, id: module.id)
        if let index = modules.firstIndex(where: { $0.id == module.id }),
           let converted = try? await modulePreviewProvider.convertedComponentContent(for: module) {
            modules[index].overrideBaseHash = Data(converted.utf8).sha256String
            modules[index].hasOverrideConflict = false
        }
        await rebuildCombinedFromCache()
        try persistModules()
        statusMessage = settings.automaticallyPublish ? "已写入 \(module.name)，等待合并发布" : "已写入 \(module.name)"
    }

    func restorePreviewContent(for module: RelayModule) async throws -> String {
        guard !isWorking else { throw RelayError.invalidOutput("当前正在更新，请稍后再恢复。") }
        beginWork(.restoringPreview)
        defer { endWork(.restoringPreview) }
        registerLocalChange()
        try await fileStore.removeComponentOverride(id: module.id)
        let content = try await modulePreviewProvider.convertedComponentContent(for: module)
        if let index = modules.firstIndex(where: { $0.id == module.id }) {
            modules[index].overrideBaseHash = nil
            modules[index].hasOverrideConflict = false
            try? persistModules()
        }
        await rebuildCombinedFromCache()
        statusMessage = settings.automaticallyPublish
            ? "已恢复 \(module.name) 的转换结果，等待合并发布"
            : "已恢复 \(module.name) 的转换结果"
        let materialized = await processingWorker.materialize(content, overrides: module.argumentOverrides)
        return await processingWorker.applyingModuleMetadata(
            name: module.name,
            category: module.category,
            to: materialized
        )
    }

    func acceptOverrideConflict(moduleID: UUID) async {
        guard let index = modules.firstIndex(where: { $0.id == moduleID }),
              let converted = try? await modulePreviewProvider.convertedComponentContent(for: modules[index]) else { return }
        modules[index].overrideBaseHash = Data(converted.utf8).sha256String
        modules[index].hasOverrideConflict = false
        try? persistModules()
        statusMessage = "已保留 \(modules[index].name) 的本地编辑"
    }

    func convertedPreviewContent(for module: RelayModule) async throws -> String {
        try await modulePreviewProvider.convertedPreviewContent(for: module)
    }

    func installationDiagnostics() -> InstallationDiagnosticSnapshot {
        InstallationDiagnosticSnapshot.current()
    }

    func credentialDiagnostics() -> CredentialDiagnosticSnapshot {
        CredentialDiagnosticSnapshot.current(
            githubTokenStatus: githubTokenStorageStatus,
            webAccessTokenStatus: webAccessTokenStorageStatus,
            keychainAccessProbe: keychainAccessProbe
        )
    }

    func refreshKeychainAccessProbe() {
        keychainAccessProbe = .checking
        let tracksActivity = !workActivity.blocksUpdates
        if tracksActivity {
            beginWork(.checkingKeychain, blocksUpdates: false)
        }
        Task { @MainActor in
            let snapshot = await Task.detached(priority: .utility) {
                KeychainAccessProbeSnapshot.current()
            }.value
            keychainAccessProbe = snapshot
            if tracksActivity {
                endWork(.checkingKeychain)
            }
            statusMessage = snapshot.state == .available
                ? "钥匙串读写检查通过"
                : "钥匙串读写检查失败"
        }
    }

    func localModuleRootDiagnostics() -> LocalModuleRootDiagnosticSnapshot {
        LocalModuleRootDiagnosticSnapshot.current(path: settings.localModuleDirectory)
    }

    func diagnosticsData() throws -> Data {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        return try DiagnosticReportBuilder.data(for: DiagnosticReportBuildRequest(
            appVersion: version,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            settings: settings,
            modules: modules,
            upstreamState: upstreamState,
            installation: installationDiagnostics(),
            credentials: credentialDiagnostics(),
            localModuleRoot: localModuleRootDiagnostics(),
            webServerState: webServerState,
            webManagementURL: webManagementDisplayURL,
            webManagementAccessModeTitle: webManagementAccessModeTitle,
            webAccessTokenStorageStatus: webAccessTokenStorageStatus,
            automaticPublishScheduledAt: automaticPublishScheduledAt,
            automaticPublishRunsAt: automaticPublishRunsAt,
            latestGitHubPublish: latestGitHubPublish,
            workActivity: workActivity,
            statusMessage: statusMessage,
            workCancellationRequested: workCancellationRequested,
            history: updateHistory
        ))
    }

    func clearUpdateHistory() {
        updateHistory.removeAll()
        PersistenceStore.saveUpdateHistory([])
    }

    func openModule(_ id: UUID) {
        guard modules.contains(where: { $0.id == id }) else { return }
        selectedModuleID = id
        navigationRequest = .modules
    }

    private func replace(_ module: RelayModule) {
        guard let index = modules.firstIndex(where: { $0.id == module.id }) else { return }
        modules[index] = module
    }

    private func setState(id: UUID, state: ModuleUpdateState, error: String?) {
        guard let index = modules.firstIndex(where: { $0.id == id }) else { return }
        modules[index].state = state
        modules[index].lastError = error
    }

    private func persistModules() throws {
        try PersistenceStore.saveModules(modules)
    }

    private func registerLocalChange() {
        localChangeGeneration &+= 1
        cancelAutomaticPublishSchedule()
        pendingPublishPreview = nil
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

    private func shouldContinueCurrentWork(
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

    private func checkCurrentWorkCancellation() throws {
        guard !workCancellationRequested, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func enterNonCancellableWorkPhase(statusMessage message: String) throws {
        try checkCurrentWorkCancellation()
        guard workActivity.isActive else { return }
        workCancellationRequested = false
        workActivity.canCancel = false
        statusMessage = message
    }

    private func isCurrentWorkCancellation(_ error: any Error) -> Bool {
        error is CancellationError || workCancellationRequested || Task.isCancelled
    }

    private func cancelAutomaticPublishSchedule() {
        if workActivity.kind == .automaticPublishing, !workActivity.canCancel {
            clearAutomaticPublishSchedule()
            return
        }
        automaticPublishTask?.cancel()
        automaticPublishTask = nil
        clearAutomaticPublishSchedule()
    }

    private func clearAutomaticPublishSchedule() {
        automaticPublishScheduledAt = nil
        automaticPublishRunsAt = nil
    }

    private func beginWork(_ kind: WorkActivityKind, blocksUpdates: Bool? = nil) {
        let activity = WorkActivity(kind: kind, blocksUpdates: blocksUpdates)
        workCancellationRequested = false
        workActivity = activity
        isWorking = activity.blocksUpdates
    }

    private func endWork(_ kind: WorkActivityKind? = nil) {
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

    private func recordHistory(_ entries: [UpdateHistoryEntry]) {
        guard !entries.isEmpty else { return }
        updateHistory = Array((entries.reversed() + updateHistory).prefix(200))
        PersistenceStore.saveUpdateHistory(updateHistory)
    }

    private func updateFailureMessage(
        for error: any Error,
        module: RelayModule,
        sourceCheckFailure: (any Error)? = nil
    ) -> String {
        let current = modules.first(where: { $0.id == module.id }) ?? module
        return UpdateFailureFormatter.detailedMessage(
            for: error,
            sourceURL: current.effectiveOriginalSourceURL,
            sourceCheckError: sourceCheckFailure
        )
    }

    private func sourceCheckFailureAfterConversionFailure(
        _ error: any Error,
        module: RelayModule,
        existingFailure: (any Error)?
    ) async -> (any Error)? {
        if let existingFailure { return existingFailure }
        guard !UpdateFailureFormatter.isActionableNetworkFailure(error),
              module.hasRemoteOriginalSource else {
            return nil
        }

        do {
            _ = try await sourceRevisionService.check(module)
            return nil
        } catch {
            return error
        }
    }

    private func missingCacheFailureDetail(moduleName: String, failureMessage: String) -> String {
        let indentedMessage = failureMessage.replacingOccurrences(of: "\n", with: "\n  ")
        return "- \(moduleName)：\(indentedMessage)"
    }

    private var hasGitHubPublishableModuleSelection: Bool {
        githubPublishPlan.hasPublishableModuleSelection
    }

    private var githubPublishPlan: PublishPlan {
        PublishCoordinator.plan(
            modules: modules,
            combinedModuleEnabled: settings.combinedModuleEnabled
        )
    }

    private var modulePreviewProvider: ModulePreviewContentProvider {
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

    private func isNoFilesToPublish(_ error: any Error) -> Bool {
        guard let relayError = error as? RelayError,
              case .noFilesToPublish = relayError else {
            return false
        }
        return true
    }

    private func hasGitHubAutomaticPublishableFiles() async -> Bool {
        await AutomaticPublishPlanner.hasCachedStandaloneOutput(
            plan: githubPublishPlan
        ) { [fileStore] id in
            await fileStore.hasComponent(id: id)
        }
    }

    private func localModuleOutputFolders() -> [String] {
        (try? LocalModuleFolderScanner.folders(in: settings.localModuleDirectory)) ?? []
    }

    private func githubPublishRepositoryKey(_ settings: GitHubSettings) -> String {
        PublishCoordinator.repositoryKey(settings)
    }

    private func githubPublishRetryPrefix(_ report: PublishReport) -> String {
        PublishCoordinator.retryPrefix(report)
    }

    private func recordGitHubPublish(_ report: PublishReport) {
        guard report.changedFileCount > 0 || report.commitSHA != nil else { return }
        recordHistory([UpdateHistoryEntry(
            moduleName: "GitHub",
            outcome: .published,
            duration: 0,
            message: githubPublishHistoryMessage(commit: report.commitSHA, report: report),
            contentChanged: report.changedFileCount > 0,
            publishedFiles: report.publishedFiles,
            deletedFiles: report.deletedFiles,
            commitSHA: report.commitSHA
        )])
    }

    private func githubPublishHistoryMessage(commit: String?, report: PublishReport) -> String {
        let suffix = report.retriedAfterConflict ? "（已处理远端更新）" : ""
        let commitText = commit.map { "原子提交 \($0.prefix(8))" } ?? "GitHub 内容已发布"
        return "\(commitText)：上传/更新 \(report.publishedFiles.count) 个，删除 \(report.deletedFiles.count) 个\(suffix)"
    }

}
