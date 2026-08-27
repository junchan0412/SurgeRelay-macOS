import Foundation

struct PublishFileAssemblyRequest {
    var plan: PublishPlan
    var combinedData: Data?
    var combinedFileName: String
    var includeAssets: Bool
    var destination: PublishDestination
    var localModuleDirectory: String
}

enum PublishFileAssembler {
    typealias ComponentReader = (UUID) async -> String?
    typealias AssetReader = (Set<UUID>) async throws -> [PublishFile]
    typealias Materializer = (String, [String: String]) async -> String
    typealias MetadataApplier = (String, String, String?, String) async -> String
    typealias CancellationCheckpoint = @MainActor () async throws -> Void

    @MainActor
    static func files(
        request: PublishFileAssemblyRequest,
        readComponent: ComponentReader,
        generatedAssetFiles: AssetReader,
        materialize: Materializer,
        applyingModuleMetadata: MetadataApplier,
        cancellationCheckpoint: CancellationCheckpoint
    ) async throws -> [PublishFile] {
        var files: [PublishFile] = []
        if request.plan.includesCombined, let combinedData = request.combinedData {
            files.append(PublishFile(
                name: FilenameSanitizer.sgmoduleName(from: request.combinedFileName),
                data: combinedData
            ))
        }
        for module in request.plan.standaloneModules {
            try await cancellationCheckpoint()
            try Task.checkCancellation()
            if PublishCoordinator.shouldSkipStandaloneLocalExport(
                module,
                isLocalExport: request.destination == .local,
                localModuleDirectory: request.localModuleDirectory
            ) {
                continue
            }
            guard let content = await readComponent(module.id) else { continue }
            let materialized = await materialize(content, module.argumentOverrides)
            let namedContent = await applyingModuleMetadata(
                module.name,
                module.category,
                module.customIconURL,
                materialized
            )
            // Write the Script-Hub `#SUBSCRIBED` marker into the exported source
            // file so on-disk output carries the original subscription/conversion
            // URL — matching the in-app preview instead of only living in the
            // project cache, which keeps re-import/provenance recovery lossless.
            let subscription = ModuleMetadataParser.scriptHubSubscription(for: module)
            let subscribedContent = ModuleMetadataParser.applyingScriptHubSubscription(
                subscription,
                to: namedContent
            )
            files.append(PublishFile(name: module.publishedRelativePath, data: Data(subscribedContent.utf8)))
        }
        if request.includeAssets {
            try await cancellationCheckpoint()
            files.append(contentsOf: try await generatedAssetFiles(request.plan.assetModuleIDs))
        }
        return files
    }
}
