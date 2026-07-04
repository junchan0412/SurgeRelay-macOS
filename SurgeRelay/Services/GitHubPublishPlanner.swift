import Foundation

struct GitHubPublishedPathPlan: Equatable, Sendable {
    var repositoryKey: String
    var currentPaths: [String]
    var stalePaths: [String]
}

struct GitHubPublishedPathUpdate: Equatable, Sendable {
    var repositoryKey: String
    var publishedPaths: [String]
}

enum GitHubPublishPlanner {
    static func pathPlan(
        currentPaths: [String],
        settings: GitHubSettings,
        knownRepositoryKey: String?,
        knownPublishedPaths: [String]
    ) -> GitHubPublishedPathPlan {
        let repositoryKey = PublishCoordinator.repositoryKey(settings)
        let matchesKnownRepository = knownRepositoryKey.map { $0 == repositoryKey } ?? false
        let stalePaths = matchesKnownRepository
            ? knownPublishedPaths.filter { !currentPaths.contains($0) }
            : []
        return GitHubPublishedPathPlan(
            repositoryKey: repositoryKey,
            currentPaths: currentPaths,
            stalePaths: stalePaths
        )
    }

    static func selectedPublishPathUpdate(
        currentPaths: [String],
        settings: GitHubSettings,
        knownRepositoryKey: String?,
        knownPublishedPaths: [String]
    ) -> GitHubPublishedPathUpdate {
        let repositoryKey = PublishCoordinator.repositoryKey(settings)
        let matchesKnownRepository = knownRepositoryKey.map { $0 == repositoryKey } ?? false
        let knownPaths = matchesKnownRepository ? knownPublishedPaths : []
        return GitHubPublishedPathUpdate(
            repositoryKey: repositoryKey,
            publishedPaths: Array(Set(knownPaths).union(currentPaths)).sorted()
        )
    }

    static func isNoFilesToPublish(_ error: any Error) -> Bool {
        guard let relayError = error as? RelayError,
              case .noFilesToPublish = relayError else {
            return false
        }
        return true
    }

    static func successMessage(scopeTitle: String, report: PublishReport) -> String {
        "\(PublishCoordinator.retryPrefix(report))\(scopeTitle)已发布到 GitHub（\(report.changedFileCount) 个文件变更）"
    }

    static func automaticSuccessMessage(report: PublishReport) -> String {
        "\(PublishCoordinator.retryPrefix(report))已合并发布到 GitHub（\(report.changedFileCount) 个文件变更）"
    }

    static func selectedSuccessMessage(report: PublishReport) -> String {
        "\(PublishCoordinator.retryPrefix(report))已发布所选模块到 GitHub（\(report.changedFileCount) 个文件变更）"
    }

    static func historyEntry(for report: PublishReport) -> UpdateHistoryEntry? {
        guard report.changedFileCount > 0 || report.commitSHA != nil else { return nil }
        return UpdateHistoryEntry(
            moduleName: "GitHub",
            outcome: .published,
            duration: 0,
            message: historyMessage(commit: report.commitSHA, report: report),
            contentChanged: report.changedFileCount > 0,
            publishedFiles: report.publishedFiles,
            deletedFiles: report.deletedFiles,
            commitSHA: report.commitSHA
        )
    }

    static func historyMessage(commit: String?, report: PublishReport) -> String {
        let suffix = report.retriedAfterConflict ? "（已处理远端更新）" : ""
        let commitText = commit.map { "原子提交 \($0.prefix(8))" } ?? "GitHub 内容已发布"
        return "\(commitText)：上传/更新 \(report.publishedFiles.count) 个，删除 \(report.deletedFiles.count) 个\(suffix)"
    }
}
