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
    var adoptedLocalPublishedPath: String?

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
        let storageTitle = storageTargetsTitle(draft.storageTargets)
        let isWarning = draft.publishesStandalone && (
            (draft.storageTargets.contains(.local) && !publishToLocal) ||
            (draft.storageTargets.contains(.gitHub) && !publishToGitHub)
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
        if draft.storageTargets.contains(.local) && draft.storageTargets.contains(.gitHub) {
            if isWarning { return "该模块同时发布到本地和 GitHub；请开启对应的全局发布开关。" }
            return "双目标模块：转换结果会同时写入本地模块根目录并发布到 GitHub。两端内容不一致时，更新会暂停并要求选择覆盖方向。"
        }
        if !draft.publishesStandalone {
            return "未开启独立发布：转换结果保存在本地缓存，不会写入独立模块目录。"
        }
        if isWarning {
            return "该模块的部分发布目标尚未开启；开启对应的本地或 GitHub 发布后才会生成独立文件。"
        }
        return switch (draft.storageLocation, initialSource) {
        case (_, .pending):
            "保存并更新后会解析转换内容中的 #SUBSCRIBED originalURL；没有该记录时，远程地址归类为远程来源，本地文件归类为自写模块。"
        case (.local, .selfAuthored):
            "自写模块：未检测到 #SUBSCRIBED originalURL，文件由本地根目录管理。"
        case (.local, .remote):
            "远程来源：从更新地址更新，转换结果保存在本地模块根目录。"
        case (.local, .subscribed):
            "订阅模块：从 originalURL 更新，转换结果保存在本地模块根目录。"
        case (.gitHub, .selfAuthored):
            "自写模块：未检测到 #SUBSCRIBED originalURL，独立输出发布到 GitHub。"
        case (.gitHub, .remote):
            "远程来源：从更新地址更新，转换结果发布到 GitHub 模块目录。"
        case (.gitHub, .subscribed):
            "订阅模块：从 originalURL 更新，转换结果发布到 GitHub 模块目录。"
        case (_, .invalid):
            "来源地址格式无效；请填写 HTTP、HTTPS 或本地 Surge 模块地址。"
        }
    }

    private static func storageTargetsTitle(_ targets: Set<ModuleStorageLocation>) -> String {
        switch (targets.contains(.local), targets.contains(.gitHub)) {
        case (true, true): "本地 + GitHub"
        case (true, false): "本地模块"
        case (false, true): "GitHub 模块"
        default: "未设置存放位置"
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
        var module = RelayModule(
            name: normalizedDraft.name,
            sourceURL: normalizedDraft.source,
            sourceFormat: draft.sourceFormat,
            outputFileName: normalizedDraft.outputFileName,
            category: normalizedDraft.category,
            outputFolder: normalizedDraft.outputFolder,
            storageLocation: draft.storageLocation,
            storageTargets: draft.storageTargets,
            localStorageRelativePath: normalizedDraft.localStorageRelativePath,
            preservesOutputFileName: draft.storageTargets.contains(.local),
            publishesStandalone: draft.publishesStandalone,
            isEnabled: draft.isEnabled,
            scriptHubOptions: draft.scriptHubOptions,
            iconURL: normalizedDraft.customIconURL,
            customIconURL: normalizedDraft.customIconURL,
            detectedSourceFormat: normalizedDraft.detectedSourceFormat
        )
        if module.scriptHubSubscription == nil {
            module.scriptHubSubscription = ModuleMetadataParser.scriptHubSubscription(
                from: normalizedDraft.source
            )
        }
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
            current.storageTargets != draft.storageTargets ||
            current.localStorageRelativePath != normalizedDraft.localStorageRelativePath ||
            current.preservesOutputFileName != draft.storageTargets.contains(.local) ||
            current.publishesStandalone != draft.publishesStandalone ||
            current.isEnabled != draft.isEnabled ||
            current.scriptHubOptions != draft.scriptHubOptions ||
            current.customIconURL != normalizedDraft.customIconURL

        guard hasChanges else {
            return ModuleDraftUpdatePlan(
                module: current,
                hasChanges: false,
                sourceChanged: false,
                customIconChanged: false,
                adoptedLocalPublishedPath: nil
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
        module.storageTargets = draft.storageTargets
        module.localStorageRelativePath = normalizedDraft.localStorageRelativePath
        module.preservesOutputFileName = draft.storageTargets.contains(.local)
        module.publishesStandalone = draft.publishesStandalone
        module.isEnabled = draft.isEnabled
        module.scriptHubOptions = draft.scriptHubOptions
        module.customIconURL = normalizedDraft.customIconURL
        module.detectedSourceFormat = normalizedDraft.detectedSourceFormat
        if sourceChanged {
            clearSourceRevisionState(&module)
        }
        if module.scriptHubSubscription == nil {
            module.scriptHubSubscription = ModuleMetadataParser.scriptHubSubscription(
                from: normalizedDraft.source
            )
        }
        if sourceChanged || customIconChanged {
            module.iconURL = normalizedDraft.customIconURL
        }
        let adoptedLocalPublishedPath: String? = if current.sourceURL != normalizedDraft.source,
                                                   URL(string: current.sourceURL)?.isFileURL == true,
                                                   let newSourceURL = URL(string: normalizedDraft.source),
                                                   ["http", "https"].contains(newSourceURL.scheme?.lowercased()),
                                                   module.hasLocalStorageTarget,
                                                   module.localStorageRelativePath != nil,
                                                   module.publishesStandalone {
            module.publishedRelativePath
        } else {
            nil
        }
        return ModuleDraftUpdatePlan(
            module: module,
            hasChanges: true,
            sourceChanged: sourceChanged,
            customIconChanged: customIconChanged,
            adoptedLocalPublishedPath: adoptedLocalPublishedPath
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
