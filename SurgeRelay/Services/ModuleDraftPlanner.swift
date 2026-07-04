import Foundation

struct ModuleDraftAddPlan: Equatable, Sendable {
    var module: RelayModule

    var customIconURL: String? {
        module.customIconURL
    }
}

struct ModuleDraftUpdatePlan: Equatable, Sendable {
    var module: RelayModule
    var hasChanges: Bool
    var sourceChanged: Bool
    var customIconChanged: Bool

    var customIconURL: String? {
        module.customIconURL
    }
}

enum ModuleDraftPlanner {
    static func addPlan(
        from draft: ModuleDraft,
        modules: [RelayModule],
        combinedModuleFileName: String,
        localModuleDirectory: String
    ) throws -> ModuleDraftAddPlan {
        if let message = draft.validationMessage { throw RelayError.invalidOutput(message) }
        let normalizedDraft = try normalizedDraftValues(
            draft,
            modules: modules,
            combinedModuleFileName: combinedModuleFileName,
            localModuleDirectory: localModuleDirectory
        )
        guard !modules.contains(where: {
            ModuleSourceIdentity.matches($0.effectiveOriginalSourceURL, normalizedDraft.source)
        }) else {
            throw RelayError.duplicateSourceURL
        }
        let module = RelayModule(
            name: normalizedDraft.name,
            sourceURL: normalizedDraft.source,
            sourceFormat: draft.sourceFormat,
            outputFileName: normalizedDraft.outputFileName,
            category: normalizedDraft.category,
            outputFolder: normalizedDraft.outputFolder,
            storageLocation: draft.storageLocation,
            localStorageRelativePath: normalizedDraft.localStorageRelativePath,
            preservesOutputFileName: draft.storageLocation == .local,
            publishesStandalone: draft.publishesStandalone,
            isEnabled: draft.isEnabled,
            scriptHubOptions: draft.scriptHubOptions,
            iconURL: normalizedDraft.customIconURL,
            customIconURL: normalizedDraft.customIconURL,
            detectedSourceFormat: normalizedDraft.detectedSourceFormat
        )
        return ModuleDraftAddPlan(module: module)
    }

    static func updatePlan(
        id: UUID,
        from draft: ModuleDraft,
        modules: [RelayModule],
        combinedModuleFileName: String,
        localModuleDirectory: String
    ) throws -> ModuleDraftUpdatePlan? {
        if let message = draft.validationMessage { throw RelayError.invalidOutput(message) }
        guard let current = modules.first(where: { $0.id == id }) else { return nil }
        let normalizedDraft = try normalizedDraftValues(
            draft,
            modules: modules,
            combinedModuleFileName: combinedModuleFileName,
            localModuleDirectory: localModuleDirectory,
            excluding: id
        )
        guard !modules.contains(where: {
            $0.id != id && ModuleSourceIdentity.matches($0.effectiveOriginalSourceURL, normalizedDraft.source)
        }) else {
            throw RelayError.duplicateSourceURL
        }

        let hasChanges = current.name != normalizedDraft.name ||
            current.sourceURL != normalizedDraft.source ||
            current.sourceFormat != draft.sourceFormat ||
            current.outputFileName != normalizedDraft.outputFileName ||
            current.category != normalizedDraft.category ||
            current.outputFolder != normalizedDraft.outputFolder ||
            current.storageLocation != draft.storageLocation ||
            current.localStorageRelativePath != normalizedDraft.localStorageRelativePath ||
            current.preservesOutputFileName != (draft.storageLocation == .local) ||
            current.publishesStandalone != draft.publishesStandalone ||
            current.isEnabled != draft.isEnabled ||
            current.scriptHubOptions != draft.scriptHubOptions ||
            current.customIconURL != normalizedDraft.customIconURL

        guard hasChanges else {
            return ModuleDraftUpdatePlan(
                module: current,
                hasChanges: false,
                sourceChanged: false,
                customIconChanged: false
            )
        }

        let sourceChanged = current.sourceURL != normalizedDraft.source ||
            current.sourceFormat != draft.sourceFormat ||
            current.scriptHubOptions != draft.scriptHubOptions
        let customIconChanged = current.customIconURL != normalizedDraft.customIconURL
        var module = current
        module.name = normalizedDraft.name
        module.sourceURL = normalizedDraft.source
        module.sourceFormat = draft.sourceFormat
        module.outputFileName = normalizedDraft.outputFileName
        module.category = normalizedDraft.category
        module.outputFolder = normalizedDraft.outputFolder
        module.storageLocation = draft.storageLocation
        module.localStorageRelativePath = normalizedDraft.localStorageRelativePath
        module.preservesOutputFileName = draft.storageLocation == .local
        module.publishesStandalone = draft.publishesStandalone
        module.isEnabled = draft.isEnabled
        module.scriptHubOptions = draft.scriptHubOptions
        module.customIconURL = normalizedDraft.customIconURL
        module.detectedSourceFormat = normalizedDraft.detectedSourceFormat
        if sourceChanged {
            clearSourceRevisionState(&module)
        }
        if sourceChanged || customIconChanged {
            module.iconURL = normalizedDraft.customIconURL
        }
        return ModuleDraftUpdatePlan(
            module: module,
            hasChanges: true,
            sourceChanged: sourceChanged,
            customIconChanged: customIconChanged
        )
    }

    private struct NormalizedDraftValues {
        var name: String
        var source: String
        var category: String
        var outputFolder: String
        var outputFileName: String
        var customIconURL: String?
        var detectedSourceFormat: ModuleSourceFormat?
        var localStorageRelativePath: String?
    }

    private static func normalizedDraftValues(
        _ draft: ModuleDraft,
        modules: [RelayModule],
        combinedModuleFileName: String,
        localModuleDirectory: String,
        excluding excludedID: UUID? = nil
    ) throws -> NormalizedDraftValues {
        let source = draft.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputFolder = ModuleOutputFolder.normalized(draft.outputFolder)
        let outputFileName = ModuleNamingPlanner.uniqueOutputFileName(
            for: draft,
            source: source,
            modules: modules,
            combinedModuleFileName: combinedModuleFileName,
            excluding: excludedID
        )
        let localStorageRelativePath = try ModuleNamingPlanner.localStorageRelativePath(
            storageLocation: draft.storageLocation,
            source: source,
            outputFileName: outputFileName,
            outputFolder: outputFolder,
            localModuleDirectory: localModuleDirectory
        )
        return NormalizedDraftValues(
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            source: source,
            category: draft.category.trimmingCharacters(in: .whitespacesAndNewlines),
            outputFolder: outputFolder,
            outputFileName: outputFileName,
            customIconURL: draft.normalizedCustomIconURL,
            detectedSourceFormat: ModuleNamingPlanner.detectedFormat(for: draft.sourceFormat, source: source),
            localStorageRelativePath: localStorageRelativePath
        )
    }

    private static func clearSourceRevisionState(_ module: inout RelayModule) {
        module.state = .never
        module.lastError = nil
        module.sourceETag = nil
        module.sourceLastModified = nil
        module.sourceContentHash = nil
        module.sourceCheckedAt = nil
        module.conversionEngineRevision = nil
        module.scriptHubSubscription = nil
    }
}
