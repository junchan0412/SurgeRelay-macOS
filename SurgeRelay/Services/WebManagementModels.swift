import Foundation

struct WebStatePayload: Encodable, Sendable {
    let combined: WebCombinedPayload
    let moduleEditor: WebModuleEditorPayload
    let modules: [WebModulePayload]
    var activity: WebActivityPayload
    var runtimeID: String? = nil
    var revision: UInt64? = nil
    var workspace: WebWorkspacePayload? = nil
}

struct WebWorkspacePayload: Encodable, Sendable {
    let localDirectory: String
    let githubRepository: String
    let githubBranch: String
    let historyCount: Int
    let recentHistory: [UpdateHistoryEntry]
    var id: String? = nil
    var name: String? = nil
    var isLegacyDefault = false
}

struct WebModuleProjectionCache {
    let revision: UInt64
    let settings: AppSettings
    let modules: [WebModulePayload]
}

struct WebModuleEditorPayload: Encodable, Sendable {
    let defaultStorageLocation: String
    let localOutputFolders: [String]
    let githubOutputFolders: [String]
    let publishToLocal: Bool
    let publishToGitHub: Bool
}

struct WebCombinedPayload: Encodable, Sendable {
    let name: String
    let isEnabled: Bool
    let fileName: String
    let sourceCount: Int
    let enabledCount: Int
    let lastUpdatedAt: Date?
    let subscriptionURL: String?
}

struct WebModulePayload: Encodable, Sendable {
    let id: String
    let name: String
    let sourceURL: String
    let initialSourceURL: String?
    let updateSourceURL: String
    let sourceFormat: String
    let sourceFormatTitle: String
    let initialSourceTitle: String
    let initialSourceIcon: String
    let outputFileName: String
    let publishedRelativePath: String
    let category: String
    let outputFolder: String
    let storageLocation: String
    let storageTargets: [String]
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
    var refreshIntervalMinutes: Int? = nil
    var nextRetryAt: Date? = nil
    var serverRetryAfter: Date? = nil
    var consecutiveFailureCount: Int = 0
    let conversionEngineRevision: String?
    let lastError: String?
    let iconURL: String?
    let customIconURL: String?
    let publishedURL: String?
    let advancedSummary: String?
    let hasOverrideConflict: Bool
    let hasSyncConflict: Bool
    let syncConflictLocalUpdatedAt: Date?
    let syncConflictGitHubUpdatedAt: Date?
    let scriptHubOptions: ScriptHubOptions
    let policy: String
    let includeKeywords: String
    let excludeKeywords: String
    let mitmAdd: String
    let mitmRemove: String
    let noResolve: Bool
    let enableJQ: Bool
}

struct WebActivityPayload: Encodable, Sendable {
    var runtimeID: String? = nil
    var revision: UInt64? = nil
    var workspaceID: String? = nil
    let isWorking: Bool
    let kind: String
    let title: String?
    let status: String
    let progress: Double?
    let completedCount: Int?
    let totalCount: Int?
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
    var activeStages: [WorkStageProgress]? = nil
}

struct ActionPayload: Encodable {
    let ok: Bool
    let message: String
    var content: String? = nil
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
    let storageTargets: [String]?
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
    let refreshIntervalMinutes: Int?
    let changesRefreshInterval: Bool

    private enum CodingKeys: String, CodingKey {
        case name, sourceURL, sourceFormat, storageLocation, storageTargets, category, iconURL, outputFolder, outputFileName, publishesStandalone, isEnabled, policy, includeKeywords, excludeKeywords, mitmAdd, mitmRemove, noResolve, enableJQ, scriptHubOptions, refreshIntervalMinutes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        sourceURL = try values.decode(String.self, forKey: .sourceURL)
        sourceFormat = try values.decodeIfPresent(String.self, forKey: .sourceFormat)
        storageLocation = try values.decodeIfPresent(String.self, forKey: .storageLocation)
        storageTargets = try values.decodeIfPresent([String].self, forKey: .storageTargets)
        category = try values.decodeIfPresent(String.self, forKey: .category)
        iconURL = try values.decodeIfPresent(String.self, forKey: .iconURL)
        outputFolder = try values.decodeIfPresent(String.self, forKey: .outputFolder)
        outputFileName = try values.decodeIfPresent(String.self, forKey: .outputFileName)
        publishesStandalone = try values.decodeIfPresent(Bool.self, forKey: .publishesStandalone)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled)
        policy = try values.decodeIfPresent(String.self, forKey: .policy)
        includeKeywords = try values.decodeIfPresent(String.self, forKey: .includeKeywords)
        excludeKeywords = try values.decodeIfPresent(String.self, forKey: .excludeKeywords)
        mitmAdd = try values.decodeIfPresent(String.self, forKey: .mitmAdd)
        mitmRemove = try values.decodeIfPresent(String.self, forKey: .mitmRemove)
        noResolve = try values.decodeIfPresent(Bool.self, forKey: .noResolve)
        enableJQ = try values.decodeIfPresent(Bool.self, forKey: .enableJQ)
        scriptHubOptions = try values.decodeIfPresent(ScriptHubOptions.self, forKey: .scriptHubOptions)
        refreshIntervalMinutes = try values.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes)
        changesRefreshInterval = values.contains(.refreshIntervalMinutes)
    }

    func draft(
        existing: RelayModule? = nil,
        defaultStorageLocation: ModuleStorageLocation = .gitHub
    ) throws -> ModuleDraft {
        var draft = existing.map(ModuleDraft.init(module:))
            ?? ModuleDraft(defaultStorageLocation: defaultStorageLocation)
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
            if storageTargets != nil || existing?.storageTargets.count != 2 || existing?.storageLocation != location {
                draft.storageLocation = location
            }
        }
        if let storageTargets {
            let targets = Set(storageTargets.compactMap(ModuleStorageLocation.init(rawValue:)))
            guard !targets.isEmpty, targets.count == storageTargets.count else {
                throw WebAPIError.invalidStorageLocation
            }
            draft.storageTargets = targets
        }
        if changesRefreshInterval {
            if let refreshIntervalMinutes, !(0...10080).contains(refreshIntervalMinutes) { throw WebAPIError.invalidArgument }
            draft.refreshIntervalMinutes = refreshIntervalMinutes
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

struct WebActivityEventPayload: Encodable, Sendable {
    let workspaceID: String
    let runtimeID: String
    let revision: UInt64
    let activity: WebActivityPayload
}

struct WebEventMessage: Sendable {
    let data: Data
    let revision: UInt64?
}

struct WebEventPayload: Sendable {
    let state: WebEventMessage
    let activity: WebEventMessage?
    let legacyState: WebEventMessage?
}
