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
        previousPublishedPaths: [String],
        protectedSourcePaths: [String] = []
    ) -> LocalPublishedFilePlan {
        let currentPaths = uniquePaths(files.map(\.name))
        let protectedIdentities = Set(protectedSourcePaths.map(LocalSourcePathResolver.pathIdentity))
        let knownManagedPaths = knownManagedPaths(
            targetDirectory: targetDirectory,
            previousRootDirectory: previousRootDirectory,
            previousPublishedPaths: previousPublishedPaths
        ).filter { !protectedIdentities.contains(LocalSourcePathResolver.pathIdentity($0)) }
        let currentIdentities = Set(currentPaths.map(LocalSourcePathResolver.pathIdentity))
        let stalePaths = knownManagedPaths.filter {
            !currentIdentities.contains(LocalSourcePathResolver.pathIdentity($0))
        }
        return LocalPublishedFilePlan(
            targetDirectory: LocalSourcePathResolver.canonicalDirectoryURL(for: targetDirectory)?.path ?? targetDirectory,
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
        knownManagedPaths(
            targetDirectory: preview.targetDescription,
            previousRootDirectory: previousRootDirectory,
            previousPublishedPaths: previousPublishedPaths
        )
    }

    static func mergedPaths(_ paths: [String], adding currentPaths: [String]) -> [String] {
        uniquePaths(currentPaths + paths).sorted()
    }

    static func protectedSourcePaths(modules: [RelayModule], targetDirectory: String) -> [String] {
        uniquePaths(modules.flatMap { module -> [String] in
            var paths: [String] = []
            if let sourcePath = LocalSourcePathResolver.storageRelativePath(for: module, rootDirectoryPath: targetDirectory) {
                paths.append(sourcePath)
            }
            if module.hasLocalStorageTarget, module.initialSource == .selfAuthored,
               let registeredPath = module.localStorageRelativePath,
               LocalSourcePathResolver.fileURL(relativePath: registeredPath, rootDirectoryPath: targetDirectory) != nil {
                paths.append(registeredPath)
            }
            return paths
        }).sorted()
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert(LocalSourcePathResolver.pathIdentity($0)).inserted }
    }

    private static func knownManagedPaths(
        targetDirectory: String,
        previousRootDirectory: String?,
        previousPublishedPaths: [String]
    ) -> [String] {
        guard let previousRootDirectory,
              let previousRoot = LocalSourcePathResolver.canonicalDirectoryURL(for: previousRootDirectory),
              let targetRoot = LocalSourcePathResolver.canonicalDirectoryURL(for: targetDirectory),
              previousRoot == targetRoot else { return [] }
        return uniquePaths(previousPublishedPaths)
    }

    static func confirmedCleanupPlan(
        preview: PublishPreview,
        previousRootDirectory: String?,
        previousPublishedPaths: [String],
        protectedSourcePaths: [String] = []
    ) -> LocalPublishedCleanupConfirmationPlan {
        let protectedIdentities = Set(protectedSourcePaths.map(LocalSourcePathResolver.pathIdentity))
        let obsoletePaths = uniquePaths(preview.deletedFiles).filter {
            !protectedIdentities.contains(LocalSourcePathResolver.pathIdentity($0))
        }
        return LocalPublishedCleanupConfirmationPlan(
            targetDirectory: preview.targetDescription,
            obsoleteRelativePaths: obsoletePaths,
            knownManagedRelativePaths: knownManagedPathsForConfirmedCleanup(
                preview: preview,
                previousRootDirectory: previousRootDirectory,
                previousPublishedPaths: previousPublishedPaths
            ).filter { !protectedIdentities.contains(LocalSourcePathResolver.pathIdentity($0)) },
            persistedRootDirectory: preview.targetDescription,
            persistedFilePaths: uniquePaths(preview.activeFiles).filter {
                !protectedIdentities.contains(LocalSourcePathResolver.pathIdentity($0))
            },
            statusMessage: "已清理 \(obsoletePaths.count) 个本地旧文件"
        )
    }
}
