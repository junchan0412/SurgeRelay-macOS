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
    typealias MetadataApplier = (String, String, String) async -> String
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
            let namedContent = await applyingModuleMetadata(module.name, module.category, materialized)
            files.append(PublishFile(name: module.publishedRelativePath, data: Data(namedContent.utf8)))
        }
        if request.includeAssets {
            try await cancellationCheckpoint()
            files.append(contentsOf: try await generatedAssetFiles(request.plan.assetModuleIDs))
        }
        return files
    }
}
