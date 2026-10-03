import Foundation

@MainActor
extension AppModel {
    var combinedRawURL: URL? {
        PublishedAddressResolver.combinedGitHubURL(settings: settings)
    }

    var combinedLocalFileURL: URL? {
        PublishedAddressResolver.combinedLocalFileURL(settings: settings)
    }

    var latestGitHubPublish: GitHubPublishSnapshot? {
        GitHubPublishSnapshot.latest(in: updateHistory, settings: settings.github)
    }

    func rawURL(for module: RelayModule) -> URL? {
        PublishedAddressResolver.standaloneURL(for: module, settings: settings)
    }

    func previewContent(for module: RelayModule) async throws -> String {
        try await modulePreviewProvider.previewContent(for: module)
    }

    func previewContent(_ version: ModuleVersionContent, for module: RelayModule) async -> String {
        let content = await processingWorker.materialize(version.content, overrides: module.argumentOverrides)
        let named = await processingWorker.applyingModuleMetadata(
            name: module.name, category: module.category, desc: module.moduleDescription,
            iconURL: module.customIconURL, to: content
        )
        return ModuleMetadataParser.applyingScriptHubSubscription(ModuleMetadataParser.scriptHubSubscription(for: module), to: named)
    }

    func moduleArgumentInfo(for module: RelayModule) async -> ModuleArgumentInfo {
        await modulePreviewProvider.moduleArgumentInfo(for: module)
    }

    func combinedPreviewContent() async throws -> String {
        try await modulePreviewProvider.combinedPreviewContent(
            combinedModuleEnabled: settings.combinedModuleEnabled
        )
    }

    func convertedPreviewContent(for module: RelayModule) async throws -> String {
        try await modulePreviewProvider.convertedPreviewContent(for: module)
    }

    func checkModuleContent(moduleID: UUID) async throws -> [ModuleLintIssue] {
        guard !isWorking else { throw PreviewContentSaveError.busy }
        guard let module = modules.first(where: { $0.id == moduleID }) else { throw RelayError.invalidOutput("模块已移除。") }
        beginWork(.previewingPublish)
        workActivity.title = "模块检查"
        defer { endWork(.previewingPublish) }
        let generation = localChangeGeneration
        let content = try await previewContent(for: module)
        let assets = try await fileStore.generatedAssetFiles(for: [moduleID])
        let files = [PublishFile(name: module.publishedRelativePath, data: Data(content.utf8))] + assets
        let worker = Task.detached(priority: .userInitiated) {
            ModuleLintPlanner.check(files: files, ownedModuleIDs: [moduleID])
        }
        let issues = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard generation == localChangeGeneration, modules.first(where: { $0.id == moduleID }) == module else {
            throw RelayError.invalidOutput("检查期间模块已变化，请重新检查。")
        }
        return issues
    }
}
