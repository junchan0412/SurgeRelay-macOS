import Foundation

struct PublishPlan: Equatable, Sendable {
    var standaloneModules: [RelayModule]

    var assetModuleIDs: Set<UUID> { Set(standaloneModules.map(\.id)) }
    var hasPublishableModuleSelection: Bool { !standaloneModules.isEmpty }
    var scopeTitle: String { "模块" }
}

enum PublishCoordinator {
    @MainActor
    static func executeSelected(
        attempt: SelectedPublishAttempt,
        destinations: Set<PublishDestination>,
        isCancelled: () -> Bool,
        publish: (PublishDestination) async throws -> PublishReport,
        didComplete: (SelectedPublishAttempt, PublishTargetResult) async -> Void
    ) async -> SelectedPublishAttempt {
        var attempt = attempt
        for index in attempt.results.indices {
            let destination = attempt.results[index].destination
            guard destinations.contains(destination), attempt.results[index].canRetry else { continue }
            var result = attempt.results[index]
            if isCancelled() || Task.isCancelled {
                result.status = .cancelled
                result.message = "已取消，尚未完成"
            } else {
                do {
                    let report = try await publish(destination)
                    result.status = .succeeded
                    result.publishedFiles = report.publishedFiles
                    result.commitSHA = report.commitSHA
                    result.message = report.changedFileCount == 0
                        ? "已是最新" : "已发布 \(report.changedFileCount) 个文件变更"
                } catch {
                    if error is CancellationError || isCancelled() || Task.isCancelled {
                        result.status = .cancelled
                        result.message = "已取消，请核对目标状态后重试"
                    } else if GitHubPublishPlanner.isNoFilesToPublish(error) {
                        result.status = .skipped
                        result.message = "没有可发布文件"
                    } else {
                        result.status = .failed
                        result.message = error.localizedDescription
                    }
                }
            }
            attempt.results[index] = result
            await didComplete(attempt, result)
        }
        return attempt
    }

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

    static func plan(modules: [RelayModule], destination: PublishDestination) -> PublishPlan {
        PublishPlan(standaloneModules: modules.filter { shouldPublishStandalone($0, destination: destination) })
    }

    static func shouldPublishStandalone(_ module: RelayModule, destination: PublishDestination) -> Bool {
        destination == .local ? module.hasLocalStorageTarget : module.hasGitHubStorageTarget
    }

    static func selectedPlan(modules: [RelayModule], moduleIDs: Set<UUID>, destination: PublishDestination) -> PublishPlan {
        plan(modules: modules.filter { moduleIDs.contains($0.id) }, destination: destination)
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
        return LocalSourcePathResolver.pathIdentity(sourceRelativePath)
            == LocalSourcePathResolver.pathIdentity(module.publishedRelativePath)
    }
}
