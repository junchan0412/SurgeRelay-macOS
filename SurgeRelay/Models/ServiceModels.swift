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

struct PublishFile: Sendable {
    var name: String
    var data: Data
}

struct PublishReport: Sendable {
    var publishedFiles: [String]
    var deletedFiles: [String] = []
    var commitSHA: String? = nil

    var changedFileCount: Int {
        publishedFiles.count + deletedFiles.count
    }
}

enum UpdateHistoryOutcome: String, Codable, Sendable {
    case updated
    case unchanged
    case cachedAfterFailure
    case failed
    case published

    var title: String {
        switch self {
        case .updated: "已更新"
        case .unchanged: "没有变化"
        case .cachedAfterFailure: "沿用缓存"
        case .failed: "失败"
        case .published: "已发布"
        }
    }
}

struct UpdateHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var date = Date.now
    var moduleID: UUID?
    var moduleName: String
    var outcome: UpdateHistoryOutcome
    var duration: TimeInterval
    var message: String
    var usedCache = false
    var contentChanged = false
}

struct DiagnosticModuleSnapshot: Codable, Sendable {
    var id: UUID
    var name: String
    var sourceURL: String
    var enabled: Bool
    var state: String
    var lastUpdatedAt: Date?
    var sourceCheckedAt: Date?
    var lastError: String?
    var hasOverrideConflict: Bool
}

struct DiagnosticReport: Codable, Sendable {
    var generatedAt: Date
    var appVersion: String
    var operatingSystem: String
    var engineRevision: String?
    var storageMode: String
    var githubRepository: String
    var webServerEnabled: Bool
    var webServerPort: Int
    var webServerAllowRemoteAccess: Bool
    var modules: [DiagnosticModuleSnapshot]
    var history: [UpdateHistoryEntry]
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
