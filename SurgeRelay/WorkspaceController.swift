import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceController {
    private(set) var registry: WorkspaceRegistry
    private(set) var activeModel: AppModel
    private(set) var isSwitching = false
    var errorMessage: String?
    @ObservationIgnored let store: WorkspaceStore
    @ObservationIgnored private let startsServices: Bool
    @ObservationIgnored private var retiredModels: [UUID: AppModel] = [:]

    init(store: WorkspaceStore = WorkspaceStore(), defaultContext: WorkspaceContext = .legacyDefault, startsServices: Bool = true) {
        self.store = store
        self.startsServices = startsServices
        let fallback = WorkspaceRegistry(activeID: defaultContext.id, workspaces: [WorkspaceDescriptor(context: defaultContext)])
        let loaded: WorkspaceRegistry
        do { loaded = try store.load(defaultContext: defaultContext) }
        catch { loaded = fallback; errorMessage = "无法读取工作区登记：\(error.localizedDescription)" }
        registry = loaded
        let descriptor = loaded.workspaces.first(where: { $0.id == loaded.activeID }) ?? WorkspaceDescriptor(context: defaultContext)
        do {
            try store.validate(descriptor)
            activeModel = AppModel(context: descriptor.context, persistsOnInit: false)
        } catch {
            let reason = error.localizedDescription
            let preferred = loaded.workspaces.first(where: { $0.id == defaultContext.id })
            let available = ([preferred].compactMap { $0 } + loaded.workspaces).first { descriptor in
                (try? store.validate(descriptor)) != nil
            }
            let fallbackContext = available?.context ?? defaultContext
            activeModel = AppModel(context: fallbackContext, persistsOnInit: false)
            registry = loaded
            if !registry.workspaces.contains(where: { $0.id == fallbackContext.id }) {
                registry.workspaces.append(WorkspaceDescriptor(context: fallbackContext))
            }
            registry.activeID = fallbackContext.id
            errorMessage = "无法载入上次工作区，已使用“\(fallbackContext.name)”；其他工作区登记仍保留：\(reason)"
        }
        attachRelocationCallbacks()
        if let errorMessage { activeModel.presentedError = errorMessage }
    }

    func createWorkspace(name: String) async throws {
        guard !isSwitching else { throw PreviewContentSaveError.busy }
        guard !activeModel.workActivity.isActive || activeModel.workActivity.canCancel else { throw PreviewContentSaveError.busy }
        registry = try store.create(name: name, in: registry)
        guard let created = registry.workspaces.last else { return }
        try await switchWorkspace(to: created.id)
    }

    func renameWorkspace(id: UUID, name: String) throws {
        guard !isSwitching, !activeModel.isWorking else { throw PreviewContentSaveError.busy }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = registry.workspaces.firstIndex(where: { $0.id == id }) else {
            throw RelayError.invalidOutput("请输入有效的工作区名称。")
        }
        var next = registry
        next.workspaces[index].name = name
        try store.save(next)
        registry = next
        if activeModel.workspaceID == id { activeModel.workspaceName = name }
    }

    func switchWorkspace(to id: UUID) async throws {
        guard !isSwitching else { throw PreviewContentSaveError.busy }
        guard id != activeModel.workspaceID else { return }
        guard let target = registry.workspaces.first(where: { $0.id == id }) else { throw RelayError.invalidOutput("工作区不存在。") }
        guard !activeModel.workActivity.isActive || activeModel.workActivity.canCancel else {
            throw RelayError.invalidOutput("当前任务不可取消，暂时不能切换工作区。")
        }
        isSwitching = true
        defer { isSwitching = false }
        let old = activeModel
        do {
            let store = store
            try await Task.detached(priority: .utility) { try store.validate(target) }.value
            try await old.prepareForWorkspaceSwitch()
            try store.validate(target)
            let nextModel = AppModel(context: target.context, persistsOnInit: false)
            var next = registry
            next.activeID = id
            try store.save(next)
            old.finishWorkspaceRetirement()
            retiredModels[old.runtimeID] = old
            registry = next
            activeModel = nextModel
            attachRelocationCallbacks()
            if startsServices { nextModel.start(performLaunchRefresh: false) }
            nextModel.statusMessage = "已切换到“\(target.name)”"
        } catch {
            if old.isWorkspaceTransitioning { old.resumeAfterWorkspaceSwitchFailure() }
            throw error
        }
    }

    func migrateWorkspace(id: UUID, to destinationRoot: URL) async throws {
        guard !isSwitching else { throw PreviewContentSaveError.busy }
        guard let source = registry.workspaces.first(where: { $0.id == id }) else {
            throw RelayError.invalidOutput("工作区不存在。")
        }
        let movesActiveWorkspace = activeModel.workspaceID == id
        guard !activeModel.workActivity.isActive || activeModel.workActivity.canCancel else {
            throw RelayError.invalidOutput("当前任务不可取消，暂时不能迁移工作区。")
        }
        isSwitching = true
        defer { isSwitching = false }
        let old = activeModel
        do {
            let store = store
            try await Task.detached(priority: .utility) { try store.validate(source) }.value
            for model in retiredModels.values where model.workspaceID == id {
                await model.flushPreviewDrafts()
                try await model.flushPersistence()
                if let problem = model.previewDraftPersistenceError { throw RelayError.invalidOutput(problem) }
            }
            if movesActiveWorkspace {
                try await old.prepareForWorkspaceSwitch()
            } else if source.isLegacyDefault,
                      !FileManager.default.fileExists(atPath: source.configurationDirectory.appending(path: "modules.json").path) ||
                        !FileManager.default.fileExists(atPath: source.configurationDirectory.appending(path: "settings.json").path) {
                let materialized = AppModel(context: source.context, persistsOnInit: false)
                try await materialized.prepareForWorkspaceSwitch()
                materialized.finishWorkspaceRetirement()
            }
            let selectedModuleID = old.selectedModuleID
            let settingsPage = old.settingsPage
            let presentsSettings = old.presentsSettings
            let toolDraft = old.conversionToolDraft
            let toolResult = old.nativeToolResult
            let toolError = old.nativeToolError
            let current = registry
            let next = try await Task.detached(priority: .utility) {
                try store.migrateWorkspace(id: id, to: destinationRoot, registry: current)
            }.value
            guard let destination = next.workspaces.first(where: { $0.id == id }) else { return }
            if source.isLegacyDefault {
                PersistenceStore.selectConfigurationDirectory(destination.configurationDirectory)
                PersistenceStore.selectCacheDirectory(destination.cacheDirectory)
            }
            registry = next
            for model in retiredModels.values where model.workspaceID == id { await model.configurationWriter.retire() }
            if movesActiveWorkspace {
                await old.configurationWriter.retire()
                let nextModel = AppModel(context: destination.context, persistsOnInit: false)
                nextModel.selectedModuleID = selectedModuleID
                nextModel.settingsPage = settingsPage
                nextModel.presentsSettings = presentsSettings
                nextModel.conversionToolDraft = toolDraft
                nextModel.nativeToolResult = toolResult
                nextModel.nativeToolError = toolError
                old.finishWorkspaceRetirement()
                retiredModels[old.runtimeID] = old
                activeModel = nextModel
                attachRelocationCallbacks()
                if startsServices { nextModel.start(performLaunchRefresh: false) }
                nextModel.statusMessage = "已迁移“\(destination.name)”的配置、草稿、历史和缓存"
            }
            retiredModels = retiredModels.filter { $0.value.workspaceID != id }
            do {
                let notice = try await Task.detached(priority: .utility) {
                    try store.removeMigratedWorkspaceData(from: source, to: destination, registry: next)
                }.value
                errorMessage = notice
                if movesActiveWorkspace, let notice { activeModel.statusMessage = notice }
            } catch {
                errorMessage = "工作区已迁移到新目录；部分旧数据尚未清理：\(error.localizedDescription)"
                if movesActiveWorkspace { activeModel.statusMessage = errorMessage! }
            }
        } catch {
            if movesActiveWorkspace, old.isWorkspaceTransitioning { old.resumeAfterWorkspaceSwitchFailure() }
            throw error
        }
    }

    func finishViewRetirement(_ model: AppModel) async {
        if let workspace = registry.workspaces.first(where: { $0.id == model.workspaceID }),
           workspace.configurationDirectory.standardizedFileURL.resolvingSymlinksInPath() != model.configurationStorageDirectory.standardizedFileURL.resolvingSymlinksInPath() ||
            workspace.cacheDirectory.standardizedFileURL.resolvingSymlinksInPath() != model.cacheDirectoryURL.standardizedFileURL.resolvingSymlinksInPath() {
            retiredModels.removeValue(forKey: model.runtimeID)
            return
        }
        await model.flushPreviewDrafts()
        try? await model.flushPersistence()
        if model.previewDraftPersistenceError == nil, model.persistenceError == nil {
            retiredModels.removeValue(forKey: model.runtimeID)
        }
    }

    func flushAllWorkspaces() async throws {
        while isSwitching { try await Task.sleep(for: .milliseconds(20)) }
        let models = [activeModel] + Array(retiredModels.values)
        for model in models {
            await model.configurationMigrationTask?.value
            await model.flushPreviewDrafts()
            try await model.flushPersistence()
            if let message = model.previewDraftPersistenceError { throw RelayError.invalidOutput(message) }
        }
    }

    private func attachRelocationCallbacks() {
        let store = store
        let id = activeModel.workspaceID
        let fallback = registry
        activeModel.configurationRelocationCommit = { directory in
            try store.relocate(id: id, to: directory, fallback: fallback)
        }
        activeModel.configurationRelocationValidation = { [weak self] directory in
            guard let self else { return }
            guard !isSwitching else { throw PreviewContentSaveError.busy }
            try store.validateRelocation(id: id, to: directory, registry: registry)
        }
        activeModel.configurationRelocationFinished = { [weak self] directory in
            guard let self, let index = registry.workspaces.firstIndex(where: { $0.id == id }) else { return }
            registry.workspaces[index].configurationDirectory = directory
        }
    }
}
