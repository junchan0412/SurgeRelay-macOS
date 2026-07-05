import Foundation

struct ConversionResult: Sendable {
    var content: String
    var requestURL: URL
    var assets: [GeneratedAsset] = []
}

struct GeneratedAsset: Sendable {
    var relativePath: String
    var data: Data
}

struct ModuleCollectionSummary: Equatable, Sendable {
    var totalCount = 0
    var enabledCount = 0
    var standaloneCount = 0
    var failedCount = 0
    var overrideConflictCount = 0
    var updateableCount = 0
    var latestUpdatedAt: Date?

    var attentionCount: Int {
        failedCount + overrideConflictCount
    }

    var hasFailures: Bool {
        failedCount > 0
    }

    init(
        modules: [RelayModule],
        isUpdateable: (RelayModule) -> Bool
    ) {
        for module in modules {
            totalCount += 1
            if module.isEnabled { enabledCount += 1 }
            if module.publishesStandalone { standaloneCount += 1 }
            if module.state == .failed { failedCount += 1 }
            if module.hasOverrideConflict { overrideConflictCount += 1 }
            if isUpdateable(module) { updateableCount += 1 }
            if let lastUpdatedAt = module.lastUpdatedAt {
                if let currentLatest = latestUpdatedAt {
                    if lastUpdatedAt > currentLatest { latestUpdatedAt = lastUpdatedAt }
                } else {
                    latestUpdatedAt = lastUpdatedAt
                }
            }
        }
    }
}

struct SourceRevisionSnapshot: Sendable {
    var etag: String?
    var lastModified: String?
    var contentHash: String
    var checkedAt: Date
}

enum SourceRevisionResult: Sendable {
    case unchanged(SourceRevisionSnapshot)
    case changed(SourceRevisionSnapshot)
}

struct UpstreamUpdateResult: Sendable {
    var revision: String
    var changed: Bool
    var scripts: [String: Data]
    var sourceDescription: String
    var upstreamRevision: String
    var scriptHashes: [String: String]
}

enum RelayError: LocalizedError, Sendable {
    case invalidSourceURL
    case invalidServiceURL
    case duplicateSourceURL
    case invalidOutput(String)
    case httpFailure(status: Int, message: String)
    case githubNotConfigured
    case githubTokenMissing
    case noFilesToPublish

    var errorDescription: String? {
        switch self {
        case .invalidSourceURL: "来源地址无效。"
        case .invalidServiceURL: "Script-Hub 服务地址无效。"
        case .duplicateSourceURL: "该模块已经添加，不能重复添加。"
        case .invalidOutput(let message): "转换结果无效：\(message)"
        case .httpFailure(let status, let message): "网络请求失败（\(status)）：\(message)"
        case .githubNotConfigured: "请先填写 GitHub 仓库信息。"
        case .githubTokenMissing: "请先保存 GitHub Token。"
        case .noFilesToPublish: "没有可发布的模块文件。"
        }
    }
}
