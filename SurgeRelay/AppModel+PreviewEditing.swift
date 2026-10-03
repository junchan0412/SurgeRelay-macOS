import Foundation

@MainActor
extension AppModel {
    @discardableResult
    func savePreviewContent(_ content: String, for requestedModule: RelayModule, expectedContentHash: String? = nil) async throws -> PreviewSaveResult {
        guard !isWorking else { throw PreviewContentSaveError.busy }
        guard let module = modules.first(where: { $0.id == requestedModule.id }) else {
            throw RelayError.invalidOutput("模块已移除，无法保存。")
        }
        beginWork(.savingPreview)
        defer { endWork(.savingPreview) }
        var generation = localChangeGeneration
        if let expectedContentHash {
            let currentPreview = try await modulePreviewProvider.previewContent(for: module)
            try checkPreviewMutationContext(module, generation: generation)
            guard Data(currentPreview.utf8).sha256String == expectedContentHash else { throw PreviewContentSaveError.changed }
        }
        let namedContent = await processingWorker.applyingModuleMetadata(
            name: module.name, category: module.category, desc: module.moduleDescription,
            iconURL: module.customIconURL, to: content
        )
        try checkPreviewMutationContext(module, generation: generation)
        let currentContent = try? await modulePreviewProvider.componentContent(for: module)
        try checkPreviewMutationContext(module, generation: generation)
        if currentContent == namedContent {
            statusMessage = "内容没有变化"
            let preview = try await modulePreviewProvider.previewContent(for: module)
            try checkPreviewMutationContext(module, generation: generation)
            return PreviewSaveResult(content: preview)
        }
        registerLocalChange()
        generation = localChangeGeneration
        let convertedContent = try? await modulePreviewProvider.convertedComponentContent(for: module)
        try checkPreviewMutationContext(module, generation: generation)
        let plan = ModulePreviewEditPlanner.savePlan(
            module: module, namedContent: namedContent, currentContent: currentContent,
            convertedContent: convertedContent, automaticallyPublish: settings.automaticallyPublish
        )
        _ = try await fileStore.recordCurrentVersion(id: module.id, reason: .beforeEdit)
        try checkPreviewMutationContext(module, generation: generation)
        try await fileStore.writeComponentOverride(plan.overrideContent, id: module.id)
        try checkPreviewMutationContext(module, generation: generation)
        replace(plan.module)
        let refreshedOutput = await rebuildCombinedFromCache()
        try checkPreviewMutationContext(plan.module, generation: generation)
        try persistModules()
        try await flushPersistence()
        statusMessage = refreshedOutput ? plan.statusMessage : "文本修改已保存，输出刷新未完成"
        let preview = try await modulePreviewProvider.previewContent(for: plan.module)
        try checkPreviewMutationContext(plan.module, generation: generation)
        return PreviewSaveResult(content: preview)
    }

    func restorePreviewContent(for requestedModule: RelayModule, expectedContentHash: String? = nil) async throws -> String {
        guard !isWorking else { throw PreviewContentSaveError.busy }
        guard let module = modules.first(where: { $0.id == requestedModule.id }) else {
            throw RelayError.invalidOutput("模块已移除，无法恢复。")
        }
        beginWork(.restoringPreview)
        defer { endWork(.restoringPreview) }
        if let expectedContentHash {
            let current = try await modulePreviewProvider.previewContent(for: module)
            guard Data(current.utf8).sha256String == expectedContentHash else { throw PreviewContentSaveError.changed }
        }
        registerLocalChange()
        let generation = localChangeGeneration
        _ = try await modulePreviewProvider.convertedComponentContent(for: module)
        try checkPreviewMutationContext(module, generation: generation)
        _ = try await fileStore.recordCurrentVersion(id: module.id, reason: .beforeRestore)
        try checkPreviewMutationContext(module, generation: generation)
        try await fileStore.removeComponentOverride(id: module.id)
        try checkPreviewMutationContext(module, generation: generation)
        let plan = ModulePreviewEditPlanner.restorePlan(module: module, automaticallyPublish: settings.automaticallyPublish)
        replace(plan.module)
        try persistModules()
        try await flushPersistence()
        let refreshedOutput = await rebuildCombinedFromCache()
        try checkPreviewMutationContext(plan.module, generation: generation)
        statusMessage = refreshedOutput ? plan.statusMessage : "已恢复转换结果，输出刷新未完成"
        let preview = try await modulePreviewProvider.previewContent(for: plan.module)
        try checkPreviewMutationContext(plan.module, generation: generation)
        return preview
    }

    func acceptOverrideConflict(moduleID: UUID) async {
        guard !isWorking else { statusMessage = PreviewContentSaveError.busy.localizedDescription; return }
        guard let module = modules.first(where: { $0.id == moduleID }) else { return }
        beginWork(.savingPreview)
        defer { endWork(.savingPreview) }
        let generation = localChangeGeneration
        do {
            let converted = try await modulePreviewProvider.convertedComponentContent(for: module)
            try checkPreviewMutationContext(module, generation: generation)
            let plan = ModulePreviewEditPlanner.acceptConflictPlan(module: module, convertedContent: converted)
            replace(plan.module)
            try persistModules()
        try await flushPersistence()
            statusMessage = plan.statusMessage
        } catch {
            presentedError = error.localizedDescription
        }
    }

    private func checkPreviewMutationContext(_ module: RelayModule, generation: Int) throws {
        guard localChangeGeneration == generation,
              let current = modules.first(where: { $0.id == module.id }), current == module else {
            throw PreviewContentSaveError.changed
        }
    }

}

@MainActor
extension AppModel {
    func schedulePreviewDraftPersistence() {
        previewDraftRevision &+= 1
        previewDraftPersistenceTask?.cancel()
        previewDraftPersistenceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await self?.flushPreviewDrafts()
        }
    }

    func flushPreviewDrafts() async {
        let revision = previewDraftRevision
        let drafts = modulePreviewDrafts
        do {
            enqueueConfiguration(drafts, fileName: "preview-drafts.json")
            try await flushPersistence()
            if previewDraftRevision == revision { previewDraftPersistenceError = nil }
        } catch {
            if previewDraftRevision == revision {
                previewDraftPersistenceError = "草稿尚未保存到磁盘：\(error.localizedDescription)"
            }
        }
    }
}

enum PreviewContentSaveError: LocalizedError, Equatable {
    case changed
    case busy

    var errorDescription: String? {
        switch self {
        case .changed: "模块内容已被其他窗口或设备修改。草稿未覆盖服务器，请重新加载并比较后再保存。"
        case .busy: "当前正在处理其他任务，请稍后再保存。"
        }
    }
}

struct PreviewSaveResult: Sendable {
    let content: String
    var contentHash: String { Data(content.utf8).sha256String }
}
