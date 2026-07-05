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

struct PublishPlan: Equatable, Sendable {
    var standaloneModules: [RelayModule]
    var combinedModuleIDs: Set<UUID>

    var includesCombined: Bool {
        !combinedModuleIDs.isEmpty
    }

    var assetModuleIDs: Set<UUID> {
        Set(standaloneModules.map(\.id)).union(combinedModuleIDs)
    }

    var hasPublishableModuleSelection: Bool {
        !standaloneModules.isEmpty || includesCombined
    }

    var hasStandaloneModuleSelection: Bool {
        !standaloneModules.isEmpty
    }

    var scopeTitle: String {
        if includesCombined {
            return standaloneModules.isEmpty ? "总模块" : "总模块与独立模块"
        }
        return "独立模块"
    }
}

enum PublishCoordinator {
    static func repositoryKey(_ settings: GitHubSettings) -> String {
        [
            settings.owner,
            settings.repository,
            settings.branch,
            settings.directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        ]
        .joined(separator: "/")
    }

    static func retryPrefix(_ report: PublishReport) -> String {
        report.retriedAfterConflict ? "远端分支已更新并重新同步；" : ""
    }

    static func plan(
        modules: [RelayModule],
        combinedModuleEnabled: Bool
    ) -> PublishPlan {
        PublishPlan(
            standaloneModules: modules.filter(\.publishesStandalone),
            combinedModuleIDs: Set(ModuleRefreshPlanner.combinedContributorModules(
                in: modules,
                combinedModuleEnabled: combinedModuleEnabled
            ).map(\.id))
        )
    }

    static func selectedPlan(
        modules: [RelayModule],
        moduleIDs: Set<UUID>
    ) -> PublishPlan {
        PublishPlan(
            standaloneModules: modules.filter { moduleIDs.contains($0.id) && $0.publishesStandalone },
            combinedModuleIDs: []
        )
    }

    static func publishableModuleIDs(
        modules: [RelayModule],
        combinedModuleEnabled: Bool
    ) -> Set<UUID> {
        plan(modules: modules, combinedModuleEnabled: combinedModuleEnabled).assetModuleIDs
    }

    static func hasPublishableModuleSelection(
        modules: [RelayModule],
        combinedModuleEnabled: Bool
    ) -> Bool {
        plan(
            modules: modules,
            combinedModuleEnabled: combinedModuleEnabled
        ).hasPublishableModuleSelection
    }

    static func shouldSkipStandaloneLocalExport(
        _ module: RelayModule,
        isLocalExport: Bool,
        localModuleDirectory: String
    ) -> Bool {
        guard isLocalExport,
              let sourceRelativePath = LocalSourcePathResolver.storageRelativePath(
                for: module,
                rootDirectoryPath: localModuleDirectory
              ) else {
            return false
        }
        return sourceRelativePath.lowercased() == module.publishedRelativePath.lowercased()
    }
}

enum LocalSourcePathResolver {
    static func storageRelativePath(
        for module: RelayModule,
        rootDirectoryPath: String
    ) -> String? {
        if module.storageLocation == .local, let relativePath = module.localStorageRelativePath {
            return ModuleOutputFolder.normalized(relativePath)
        }
        return relativePath(forSourceURL: module.sourceURL, rootDirectoryPath: rootDirectoryPath)
    }

    static func fileName(forSourceURL sourceURL: String, rootDirectoryPath: String) -> String? {
        guard let relativePath = relativePath(forSourceURL: sourceURL, rootDirectoryPath: rootDirectoryPath) else {
            return nil
        }
        return relativePath.split(separator: "/").last.map(String.init)
    }

    static func relativePath(forSourceURL sourceURL: String, rootDirectoryPath: String) -> String? {
        guard let url = URL(string: sourceURL), url.isFileURL else { return nil }
        let root = URL(filePath: rootDirectoryPath, directoryHint: .isDirectory).standardizedFileURL
        let source = url.standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard source.path.hasPrefix(rootPath) else { return nil }
        return ModuleOutputFolder.normalized(String(source.path.dropFirst(rootPath.count)))
    }
}

enum UpdateFailureFormatter {
    static func detailedMessage(
        for error: any Error,
        sourceURL: String? = nil,
        sourceCheckError: (any Error)? = nil
    ) -> String {
        let primary = baseMessage(for: error, sourceURL: sourceURL)
        guard let sourceCheckError,
              isActionableNetworkFailure(sourceCheckError),
              !isActionableNetworkFailure(error) else {
            return primary
        }

        let sourceMessage = baseMessage(for: sourceCheckError, sourceURL: sourceURL)
        guard sourceMessage != primary else { return primary }
        return "\(sourceMessage)\n转换阶段同时失败：\(primary)"
    }

    static func summary(from message: String, maxLength: Int = 42) -> String {
        let oneLine = message
            .components(separatedBy: .newlines)
            .first?
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard oneLine.count > maxLength else { return oneLine }
        return "\(oneLine.prefix(max(1, maxLength - 1)))…"
    }

    private static func baseMessage(for error: any Error, sourceURL: String?) -> String {
        if let relayError = error as? RelayError {
            switch relayError {
            case let .httpFailure(status, message):
                return httpFailureMessage(status: status, message: message, sourceURL: sourceURL)
            default:
                return relayError.localizedDescription
            }
        }

        if let urlError = error as? URLError {
            return urlErrorMessage(urlError, sourceURL: sourceURL)
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return urlErrorMessage(URLError(URLError.Code(rawValue: nsError.code)), sourceURL: sourceURL)
        }

        return error.localizedDescription
    }

    static func isActionableNetworkFailure(_ error: any Error) -> Bool {
        if let relayError = error as? RelayError,
           case .httpFailure = relayError {
            return true
        }
        if error is URLError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
    }

    private static func httpFailureMessage(status: Int, message: String, sourceURL: String?) -> String {
        let target = sourceTargetDescription(sourceURL)
        let statusText = httpStatusText(status)
        let base = switch status {
        case 404:
            "原始链接返回 \(statusText)\(target)，请检查文件是否已删除、改名、分支/路径是否变化，或仓库是否公开且当前链接有访问权限。"
        case 401:
            "原始链接返回 \(statusText)\(target)，请检查是否需要登录、Token 或访问权限。"
        case 403:
            "原始链接返回 \(statusText)\(target)，可能是仓库权限、访问频率限制或防盗链限制。"
        case 429:
            "原始链接返回 \(statusText)\(target)，请求过于频繁，请稍后重试。"
        case 500..<600:
            "原始服务器返回 \(statusText)\(target)，请稍后重试。"
        default:
            "原始链接请求失败：\(statusText)\(target)。"
        }

        let body = cleanedHTTPBody(message)
        guard !body.isEmpty else { return base }
        return "\(base)\n服务器返回：\(body)"
    }

    private static func urlErrorMessage(_ error: URLError, sourceURL: String?) -> String {
        let target = sourceTargetDescription(sourceURL)
        switch error.code {
        case .timedOut:
            return "连接原始链接超时\(target)，请稍后重试或检查网络。"
        case .cannotFindHost, .dnsLookupFailed:
            return "无法解析原始链接域名\(target)，请检查链接或 DNS。"
        case .cannotConnectToHost, .networkConnectionLost:
            return "无法连接原始链接\(target)，请检查网络后重试。"
        case .notConnectedToInternet:
            return "当前网络不可用，无法访问原始链接\(target)。"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "原始链接的 HTTPS 证书校验失败\(target)。"
        case .badURL, .unsupportedURL:
            return "原始链接格式无效\(target)。"
        default:
            return "无法访问原始链接\(target)：\(error.localizedDescription)"
        }
    }

    private static func sourceTargetDescription(_ sourceURL: String?) -> String {
        guard let sourceURL,
              !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        return "：\(redactedSourceURL(sourceURL))"
    }

    private static func redactedSourceURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? value
    }

    private static func httpStatusText(_ status: Int) -> String {
        let phrase = switch status {
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 410: "Gone"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: HTTPURLResponse.localizedString(forStatusCode: status)
        }
        return "\(status)（\(phrase)）"
    }

    private static func cleanedHTTPBody(_ message: String) -> String {
        let trimmed = message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.lowercased().hasPrefix("<!doctype html") || trimmed.lowercased().hasPrefix("<html") {
            return "HTML 错误页"
        }
        return String(trimmed.prefix(240))
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
