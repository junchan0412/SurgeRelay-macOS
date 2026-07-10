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

struct ModuleDraftRelationshipPresentation: Equatable, Sendable {
    var storageTitle: String
    var initialSource: ModuleInitialSource
    var hint: String
    var isWarning: Bool
}

enum ModuleDraftRelationshipPlanner {
    static func presentation(
        draft: ModuleDraft,
        existingModule: RelayModule?,
        publishToLocal: Bool,
        publishToGitHub: Bool
    ) -> ModuleDraftRelationshipPresentation {
        let initialSource = initialSource(draft: draft, existingModule: existingModule)
        let storageTitle = draft.storageLocation == .gitHub && !draft.publishesStandalone
            ? "远程模块"
            : draft.storageLocation.title
        let isWarning = draft.publishesStandalone && (
            draft.storageLocation == .local ? !publishToLocal : !publishToGitHub
        )
        return ModuleDraftRelationshipPresentation(
            storageTitle: storageTitle,
            initialSource: initialSource,
            hint: hint(
                draft: draft,
                initialSource: initialSource,
                isWarning: isWarning
            ),
            isWarning: isWarning
        )
    }

    private static func initialSource(
        draft: ModuleDraft,
        existingModule: RelayModule?
    ) -> ModuleInitialSource {
        let source = draft.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return .pending }
        guard let url = URL(string: source),
              url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased()) else {
            return .invalid
        }
        guard let existingModule,
              ModuleSourceIdentity.matches(existingModule.sourceURL, source) else {
            return .pending
        }
        return existingModule.initialSource
    }

    private static func hint(
        draft: ModuleDraft,
        initialSource: ModuleInitialSource,
        isWarning: Bool
    ) -> String {
        if !draft.publishesStandalone {
            return "未开启独立发布：转换结果保存在本地缓存，不会写入独立模块目录。"
        }
        if isWarning {
            return draft.storageLocation == .local
                ? "该模块设为本地存放，但全局“发布到本地”尚未开启；保存后暂不会生成独立文件。"
                : "该模块设为 GitHub 存放，但全局“发布到 GitHub”尚未开启；保存后暂不会发布独立文件。"
        }
        return switch (draft.storageLocation, initialSource) {
        case (_, .pending):
            "保存并更新后会解析转换内容中的 #SUBSCRIBED originalURL，确认模块的初始来源。"
        case (.local, .selfAuthored):
            "自写模块：未检测到 #SUBSCRIBED originalURL，文件由本地根目录管理。"
        case (.local, .subscribed):
            "订阅模块：从 originalURL 更新，转换结果保存在本地模块根目录。"
        case (.gitHub, .selfAuthored):
            "自写模块：未检测到 #SUBSCRIBED originalURL，独立输出发布到 GitHub。"
        case (.gitHub, .subscribed):
            "订阅模块：从 originalURL 更新，转换结果发布到 GitHub 模块目录。"
        case (_, .invalid):
            "来源地址格式无效；请填写 HTTP、HTTPS 或本地 Surge 模块地址。"
        }
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
            ModuleSourceIdentity.matches($0.updateSourceURL, normalizedDraft.source)
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
            $0.id != id && ModuleSourceIdentity.matches($0.updateSourceURL, normalizedDraft.source)
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
