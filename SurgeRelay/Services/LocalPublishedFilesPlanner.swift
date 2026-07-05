import Foundation

struct LocalPublishedFilePlan: Equatable, Sendable {
    var targetDirectory: String
    var currentPaths: [String]
    var knownManagedPaths: [String]
    var stalePaths: [String]

    var requiresCleanupConfirmation: Bool {
        !stalePaths.isEmpty
    }

    var cleanupStatusMessage: String {
        "已写入本地模块，等待确认清理 \(stalePaths.count) 个旧文件"
    }

    func cleanupPreview() -> PublishPreview {
        PublishPreview(
            destination: .local,
            targetDescription: targetDirectory,
            activeFiles: currentPaths,
            changedFiles: [],
            deletedFiles: stalePaths
        )
    }
}

enum LocalPublishedFileCompletion: Equatable, Sendable {
    case persisted(rootDirectory: String, filePaths: [String])
    case requiresCleanup(preview: PublishPreview, statusMessage: String)
}

struct LocalPublishedCleanupConfirmationPlan: Equatable, Sendable {
    var targetDirectory: String
    var obsoleteRelativePaths: [String]
    var knownManagedRelativePaths: [String]
    var persistedRootDirectory: String
    var persistedFilePaths: [String]
    var statusMessage: String
}

enum LocalPublishedFilesPlanner {
    static func plan(
        files: [PublishFile],
        targetDirectory: String,
        previousRootDirectory: String?,
        previousPublishedPaths: [String]
    ) -> LocalPublishedFilePlan {
        let currentPaths = files.map(\.name)
        let matchesPreviousRoot = previousRootDirectory == targetDirectory
        let knownManagedPaths = matchesPreviousRoot ? previousPublishedPaths : []
        let stalePaths = matchesPreviousRoot
            ? previousPublishedPaths.filter { !currentPaths.contains($0) }
            : []
        return LocalPublishedFilePlan(
            targetDirectory: targetDirectory,
            currentPaths: currentPaths,
            knownManagedPaths: knownManagedPaths,
            stalePaths: stalePaths
        )
    }

    static func completion(afterExporting plan: LocalPublishedFilePlan) -> LocalPublishedFileCompletion {
        if plan.requiresCleanupConfirmation {
            return .requiresCleanup(
                preview: plan.cleanupPreview(),
                statusMessage: plan.cleanupStatusMessage
            )
        }
        return .persisted(
            rootDirectory: plan.targetDirectory,
            filePaths: plan.currentPaths
        )
    }

    static func knownManagedPathsForConfirmedCleanup(
        preview: PublishPreview,
        previousRootDirectory: String?,
        previousPublishedPaths: [String]
    ) -> [String] {
        previousRootDirectory == preview.targetDescription ? previousPublishedPaths : []
    }

    static func confirmedCleanupPlan(
        preview: PublishPreview,
        previousRootDirectory: String?,
        previousPublishedPaths: [String]
    ) -> LocalPublishedCleanupConfirmationPlan {
        LocalPublishedCleanupConfirmationPlan(
            targetDirectory: preview.targetDescription,
            obsoleteRelativePaths: preview.deletedFiles,
            knownManagedRelativePaths: knownManagedPathsForConfirmedCleanup(
                preview: preview,
                previousRootDirectory: previousRootDirectory,
                previousPublishedPaths: previousPublishedPaths
            ),
            persistedRootDirectory: preview.targetDescription,
            persistedFilePaths: preview.activeFiles,
            statusMessage: "已清理 \(preview.deletedFiles.count) 个本地旧文件"
        )
    }
}
