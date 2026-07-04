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

    static func knownManagedPathsForConfirmedCleanup(
        preview: PublishPreview,
        previousRootDirectory: String?,
        previousPublishedPaths: [String]
    ) -> [String] {
        previousRootDirectory == preview.targetDescription ? previousPublishedPaths : []
    }
}
