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
    var retriedAfterConflict = false

    var changedFileCount: Int {
        publishedFiles.count + deletedFiles.count
    }
}

enum PublishDestination: String, Sendable {
    case local
    case gitHub

    var title: String {
        switch self {
        case .local: "本地"
        case .gitHub: "GitHub"
        }
    }
}

struct PublishPreview: Identifiable, Equatable, Sendable {
    var id = UUID()
    var destination: PublishDestination
    var targetDescription: String
    var activeFiles: [String]
    var changedFiles: [String]
    var deletedFiles: [String]

    var changedFileCount: Int {
        changedFiles.count + deletedFiles.count
    }

    var hasChanges: Bool {
        changedFileCount > 0
    }

    var requiresDeletionConfirmation: Bool {
        !deletedFiles.isEmpty
    }
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

enum ReleaseUpdateChannel {
    static let latestReleaseURL = URL(string: "https://github.com/junchan0412/SurgeRelay-macOS/releases/latest")!
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
    var publishedFiles: [String] = []
    var deletedFiles: [String] = []
    var commitSHA: String?

    var publishedChangeCount: Int {
        publishedFiles.count + deletedFiles.count
    }

    init(
        id: UUID = UUID(),
        date: Date = Date.now,
        moduleID: UUID? = nil,
        moduleName: String,
        outcome: UpdateHistoryOutcome,
        duration: TimeInterval,
        message: String,
        usedCache: Bool = false,
        contentChanged: Bool = false,
        publishedFiles: [String] = [],
        deletedFiles: [String] = [],
        commitSHA: String? = nil
    ) {
        self.id = id
        self.date = date
        self.moduleID = moduleID
        self.moduleName = moduleName
        self.outcome = outcome
        self.duration = duration
        self.message = message
        self.usedCache = usedCache
        self.contentChanged = contentChanged
        self.publishedFiles = publishedFiles
        self.deletedFiles = deletedFiles
        self.commitSHA = commitSHA
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, moduleID, moduleName, outcome, duration, message, usedCache, contentChanged
        case publishedFiles, deletedFiles, commitSHA
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date.now
        moduleID = try container.decodeIfPresent(UUID.self, forKey: .moduleID)
        moduleName = try container.decode(String.self, forKey: .moduleName)
        outcome = try container.decode(UpdateHistoryOutcome.self, forKey: .outcome)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        usedCache = try container.decodeIfPresent(Bool.self, forKey: .usedCache) ?? false
        contentChanged = try container.decodeIfPresent(Bool.self, forKey: .contentChanged) ?? false
        publishedFiles = try container.decodeIfPresent([String].self, forKey: .publishedFiles) ?? []
        deletedFiles = try container.decodeIfPresent([String].self, forKey: .deletedFiles) ?? []
        commitSHA = try container.decodeIfPresent(String.self, forKey: .commitSHA)
    }
}

struct GitHubPublishSnapshot: Codable, Equatable, Sendable {
    var date: Date
    var commitSHA: String?
    var commitURL: String?
    var publishedFiles: [String]
    var deletedFiles: [String]
    var message: String

    var changedFileCount: Int {
        publishedFiles.count + deletedFiles.count
    }

    var commitDisplay: String {
        guard let commitSHA, !commitSHA.isEmpty else { return "未记录" }
        return String(commitSHA.prefix(8))
    }

    var fileSummary: String {
        "\(publishedFiles.count) 个上传/更新 · \(deletedFiles.count) 个删除"
    }

    static func latest(in history: [UpdateHistoryEntry], settings: GitHubSettings) -> GitHubPublishSnapshot? {
        guard let entry = history.first(where: {
            let hasCommit = !($0.commitSHA ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return $0.outcome == .published && (
                hasCommit ||
                    !$0.publishedFiles.isEmpty ||
                    !$0.deletedFiles.isEmpty
            )
        }) else {
            return nil
        }
        return GitHubPublishSnapshot(
            date: entry.date,
            commitSHA: entry.commitSHA,
            commitURL: commitURL(for: entry.commitSHA, settings: settings),
            publishedFiles: entry.publishedFiles,
            deletedFiles: entry.deletedFiles,
            message: entry.message
        )
    }

    static func commitURL(for commitSHA: String?, settings: GitHubSettings) -> String? {
        guard settings.isConfigured,
              let commitSHA,
              !commitSHA.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let owner = settings.owner.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? settings.owner
        let repository = settings.repository.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? settings.repository
        let commit = commitSHA.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? commitSHA
        return "https://github.com/\(owner)/\(repository)/commit/\(commit)"
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

enum UpdateCoordinator {
    static func shouldRefreshScriptHub(
        missingEngine: Bool,
        settings: AppSettings,
        upstreamState: ScriptHubUpstreamState
    ) -> Bool {
        missingEngine || (
            settings.automaticallyUpdateScriptHub &&
                RefreshPolicy.isDue(
                    lastUpdatedAt: upstreamState.lastCheckedAt,
                    intervalMinutes: settings.refreshIntervalMinutes
                )
        )
    }

    static func refreshIntervalSeconds(settings: AppSettings) -> Int? {
        guard settings.refreshIntervalMinutes > 0 else { return nil }
        return settings.refreshIntervalMinutes * 60
    }
}

enum WebManagementController {
    static func accessModeTitle(settings: AppSettings) -> String {
        settings.webServerAllowRemoteAccess ? "局域网" : "仅本机"
    }

    static func host(settings: AppSettings, processInfo: ProcessInfo = .processInfo) -> String {
        guard settings.webServerAllowRemoteAccess else { return "127.0.0.1" }
        var host = processInfo.hostName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if !host.contains(".") { host += ".local" }
        return host
    }

    static func url(settings: AppSettings, accessToken: String, includingToken: Bool) -> URL? {
        guard settings.webServerEnabled else { return nil }
        return WebManagementURLFactory.url(
            host: host(settings: settings),
            port: settings.webServerPort,
            accessToken: accessToken,
            includingToken: includingToken
        )
    }
}

enum ConfigurationManager {
    static var configurationDirectoryPath: String {
        PersistenceStore.configurationDirectoryURL.path
    }

    static func migrateConfiguration(
        to path: String,
        modules: [RelayModule],
        settings: AppSettings,
        upstreamState: ScriptHubUpstreamState,
        updateHistory: [UpdateHistoryEntry]
    ) throws {
        try PersistenceStore.useConfigurationDirectory(path)
        try PersistenceStore.saveModules(modules)
        PersistenceStore.saveSettings(settings)
        PersistenceStore.saveUpstreamState(upstreamState)
        PersistenceStore.saveUpdateHistory(updateHistory)
    }
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
