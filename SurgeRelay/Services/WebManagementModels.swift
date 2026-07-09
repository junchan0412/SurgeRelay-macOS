import Foundation

struct WebStatePayload: Encodable {
    let combined: WebCombinedPayload
    let moduleOutputFolders: [String]
    let modules: [WebModulePayload]
    let activity: WebActivityPayload
}

struct WebCombinedPayload: Encodable {
    let name: String
    let isEnabled: Bool
    let fileName: String
    let sourceCount: Int
    let enabledCount: Int
    let lastUpdatedAt: Date?
    let subscriptionURL: String?
}

struct WebModulePayload: Encodable {
    let id: String
    let name: String
    let sourceURL: String
    let effectiveOriginalSourceURL: String
    let sourceFormat: String
    let sourceFormatTitle: String
    let sourceOriginTitle: String
    let sourceOriginIcon: String
    let outputFileName: String
    let publishedRelativePath: String
    let category: String
    let outputFolder: String
    let storageLocation: String
    let storageLocationTitle: String
    let storageLocationDetail: String
    let storageLocationIcon: String
    let relationshipSummary: String
    let localStorageRelativePath: String?
    let publishesStandalone: Bool
    let isEnabled: Bool
    let state: String
    let stateTitle: String
    let createdAt: Date
    let lastUpdatedAt: Date?
    let sourceCheckedAt: Date?
    let contentHash: String?
    let sourceETag: String?
    let sourceLastModified: String?
    let sourceContentHash: String?
    let conversionEngineRevision: String?
    let lastError: String?
    let iconURL: String?
    let customIconURL: String?
    let publishedURL: String?
    let advancedSummary: String?
    let hasOverrideConflict: Bool
    let scriptHubOptions: ScriptHubOptions
    let policy: String
    let includeKeywords: String
    let excludeKeywords: String
    let mitmAdd: String
    let mitmRemove: String
    let noResolve: Bool
    let enableJQ: Bool
}

struct WebActivityPayload: Encodable {
    let isWorking: Bool
    let kind: String
    let title: String?
    let status: String
    let progress: Double?
    let currentModuleID: String?
    let startedAt: Date?
    let blocksUpdates: Bool
    let canCancel: Bool
    let cancellationRequested: Bool
    let canStartUpdate: Bool
    let updateBlockedReason: String?
    let enabledModuleCount: Int
    let automaticPublishScheduledAt: Date?
    let automaticPublishRunsAt: Date?
    let latestGitHubPublish: GitHubPublishSnapshot?
    let error: String?
}

struct ActionPayload: Encodable {
    let ok: Bool
    let message: String
}

struct WebEnabledRequest: Decodable {
    let enabled: Bool
}

struct WebSourceNameRequest: Decodable {
    let url: String
}

struct WebSourceNamePayload: Encodable {
    let name: String
}

struct WebArgumentMutation: Decodable {
    let key: String
    let value: String
}

struct WebArgumentPayload: Encodable {
    let key: String
    let defaultValue: String
    let value: String
}

struct WebArgumentsPayload: Encodable {
    let arguments: [WebArgumentPayload]
    let help: String?
}

struct WebModuleMutation: Decodable {
    let name: String
    let sourceURL: String
    let sourceFormat: String?
    let storageLocation: String?
    let category: String?
    let iconURL: String?
    let outputFolder: String?
    let outputFileName: String?
    let publishesStandalone: Bool?
    let isEnabled: Bool?
    let policy: String?
    let includeKeywords: String?
    let excludeKeywords: String?
    let mitmAdd: String?
    let mitmRemove: String?
    let noResolve: Bool?
    let enableJQ: Bool?
    let scriptHubOptions: ScriptHubOptions?

    func draft(existing: RelayModule? = nil) throws -> ModuleDraft {
        var draft = existing.map(ModuleDraft.init(module:)) ?? ModuleDraft()
        draft.name = name
        draft.sourceURL = sourceURL
        if let sourceFormat {
            guard let format = ModuleSourceFormat(rawValue: sourceFormat) else {
                throw WebAPIError.invalidFormat
            }
            draft.sourceFormat = format
        }
        if let storageLocation {
            guard let location = ModuleStorageLocation(rawValue: storageLocation) else {
                throw WebAPIError.invalidStorageLocation
            }
            draft.storageLocation = location
        }
        if let category { draft.category = category }
        if let iconURL { draft.iconURL = iconURL }
        if let outputFolder { draft.outputFolder = outputFolder }
        if let outputFileName { draft.outputFileName = outputFileName }
        if let publishesStandalone { draft.publishesStandalone = publishesStandalone }
        if let isEnabled { draft.isEnabled = isEnabled }
        if let scriptHubOptions { draft.scriptHubOptions = scriptHubOptions }
        if let policy { draft.scriptHubOptions.policy = policy }
        if let includeKeywords { draft.scriptHubOptions.includeKeywords = includeKeywords }
        if let excludeKeywords { draft.scriptHubOptions.excludeKeywords = excludeKeywords }
        if let mitmAdd { draft.scriptHubOptions.mitmAdd = mitmAdd }
        if let mitmRemove { draft.scriptHubOptions.mitmRemove = mitmRemove }
        if let noResolve { draft.scriptHubOptions.noResolve = noResolve }
        if let enableJQ { draft.scriptHubOptions.enableJQ = enableJQ }
        return draft
    }
}

enum WebAPIError: LocalizedError {
    case invalidModule
    case moduleNotFound
    case methodNotAllowed
    case invalidBody
    case invalidArgument
    case invalidFormat
    case invalidStorageLocation
    case invalidSourceURL

    var status: Int {
        switch self {
        case .moduleNotFound: 404
        case .methodNotAllowed: 405
        default: 400
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidModule: "模块标识无效。"
        case .moduleNotFound: "找不到这个模块。"
        case .methodNotAllowed: "此处不支持该操作。"
        case .invalidBody: "请求内容不是有效的 UTF-8 文本。"
        case .invalidArgument: "找不到这个模块参数。"
        case .invalidFormat: "来源格式无效。"
        case .invalidStorageLocation: "模块存放位置无效。"
        case .invalidSourceURL: "来源地址无效。"
        }
    }
}
