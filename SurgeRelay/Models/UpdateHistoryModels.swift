import Foundation

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
