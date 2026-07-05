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

struct GitHubRepositoryPrivacyUpdate: Equatable, Sendable {
    var repositoryIsPrivate: Bool
    var shouldPersist: Bool
}

enum GitHubPublishAction: Equatable, Sendable {
    case publishAll
    case publishSelected
    case preview
}

enum GitHubPublishPlanner {
    static func repositoryPrivacyUpdate(
        currentValue: Bool?,
        detectedValue: Bool
    ) -> GitHubRepositoryPrivacyUpdate {
        GitHubRepositoryPrivacyUpdate(
            repositoryIsPrivate: detectedValue,
            shouldPersist: currentValue != detectedValue
        )
    }

    static func targetDescription(settings: GitHubSettings) -> String {
        let repository = "\(settings.owner)/\(settings.repository)@\(settings.branch)"
        let directory = settings.directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return directory.isEmpty ? repository : "\(repository)/\(directory)"
    }

    static func preview(
        settings: GitHubSettings,
        pathPlan: GitHubPublishedPathPlan,
        report: PublishReport
    ) -> PublishPreview {
        PublishPreview(
            destination: .gitHub,
            targetDescription: targetDescription(settings: settings),
            activeFiles: pathPlan.currentPaths,
            changedFiles: report.publishedFiles,
            deletedFiles: report.deletedFiles
        )
    }

    static func shouldPersistPathPlan(
        _ pathPlan: GitHubPublishedPathPlan,
        allowDeleting: Bool
    ) -> Bool {
        pathPlan.stalePaths.isEmpty || allowDeleting
    }

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

    static func noFilesStatus(for action: GitHubPublishAction) -> String {
        switch action {
        case .publishAll:
            return "没有可发布的模块文件"
        case .publishSelected:
            return "所选模块没有可发布的独立输出"
        case .preview:
            return "没有可发布的模块文件，已跳过 GitHub 发布预览"
        }
    }

    static func unchangedStatus(for action: GitHubPublishAction) -> String {
        switch action {
        case .publishAll:
            return "没有文件需要发布"
        case .publishSelected:
            return "所选模块没有文件需要发布"
        case .preview:
            return "GitHub 内容没有变化"
        }
    }

    static func deletionConfirmationStatus(deletedFileCount: Int) -> String {
        "发布前需要确认删除 \(deletedFileCount) 个旧文件"
    }

    static func previewStatus(_ preview: PublishPreview) -> String {
        preview.hasChanges
            ? "已生成 GitHub 发布预览（\(preview.changedFileCount) 个文件变更）"
            : unchangedStatus(for: .preview)
    }

    static func reportStatus(
        for action: GitHubPublishAction,
        report: PublishReport,
        scopeTitle: String
    ) -> String {
        guard report.changedFileCount > 0 else { return unchangedStatus(for: action) }
        switch action {
        case .publishAll:
            return successMessage(scopeTitle: scopeTitle, report: report)
        case .publishSelected:
            return selectedSuccessMessage(report: report)
        case .preview:
            return "已生成 GitHub 发布预览（\(report.changedFileCount) 个文件变更）"
        }
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
