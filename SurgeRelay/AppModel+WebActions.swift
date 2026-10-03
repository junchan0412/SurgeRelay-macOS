import Foundation

@MainActor
extension AppModel {
    func webPublishPreview(_ request: WebPublishPreviewRequest, retainsForNativeUI: Bool = false) async throws -> WebPublishPreviewPayload {
        guard !isWorking else { throw PreviewContentSaveError.busy }
        beginWork(.previewingPublish)
        defer { endWork(.previewingPublish) }
        if request.scope == "githubAll" || (request.moduleIDs ?? []).contains(where: { id in
            modules.contains { $0.id == id && $0.hasGitHubStorageTarget }
        }) || request.retryAttemptID != nil {
            if settings.publishToGitHub { _ = try await githubPublishTokenAndRefreshRepositoryPrivacy() }
        }
        let originalSettings = settings
        let generation = localChangeGeneration
        let scope = request.scope ?? "selected"
        guard scope == "selected" || scope == "githubAll" else { throw WebAPIError.invalidBody }
        var ids = request.moduleIDs ?? []
        var destinations: Set<PublishDestination> = []
        if let retryID = request.retryAttemptID {
            guard scope == "selected", let attempt = selectedPublishAttempt, attempt.id == retryID,
                  !attempt.retryDestinations.isEmpty else { throw PreviewContentSaveError.changed }
            ids = attempt.moduleIDs
            destinations = attempt.retryDestinations
            for result in attempt.results where result.canRetry {
                guard result.target == selectedPublishTarget(result.destination) else { throw PreviewContentSaveError.changed }
            }
        } else if scope == "githubAll" {
            destinations = [.gitHub]
        } else {
            guard !ids.isEmpty, ids.isSubset(of: Set(modules.map(\.id))) else { throw WebAPIError.moduleNotFound }
            destinations = Set(PublishDestination.allCases.filter {
                PublishCoordinator.selectedPlan(modules: modules, moduleIDs: ids,
                    combinedModuleEnabled: settings.combinedModuleEnabled, destination: $0).hasStandaloneModuleSelection
            })
        }
        guard !destinations.isEmpty else { throw RelayError.noFilesToPublish }
        var files: [PublishDestination: [PublishFile]] = [:]
        var previews: [PublishPreview] = []
        var localHashes: [String: String] = [:]
        var pathPlan: GitHubPublishedPathPlan?
        var head: String?
        for destination in PublishDestination.allCases where destinations.contains(destination) {
            try checkCurrentWorkCancellation()
            try validateWebPublishTarget(destination)
            let prepared = try await webPublishFiles(scope: scope, moduleIDs: ids, destination: destination)
            guard !prepared.files.isEmpty else { throw RelayError.noFilesToPublish }
            files[destination] = prepared.files
            if destination == .gitHub {
                let token = ensureGitHubTokenLoaded(showStatusMessage: false)
                let report = try await githubClient.previewPublish(files: prepared.files,
                    deleting: prepared.pathPlan?.stalePaths ?? [], settings: settings.github, token: token)
                guard let remoteHead = report.baseCommitSHA else { throw PreviewContentSaveError.changed }
                head = remoteHead
                pathPlan = prepared.pathPlan
                previews.append(PublishPreview(destination: destination,
                    targetDescription: GitHubPublishPlanner.targetDescription(settings: settings.github),
                    activeFiles: prepared.files.map(\.name), changedFiles: report.publishedFiles, deletedFiles: report.deletedFiles))
            } else {
                var changed: [String] = []
                for file in prepared.files {
                    let data = try await fileStore.readPublishedFile(relativePath: file.name, rootDirectoryPath: settings.localModuleDirectory)
                    localHashes[file.name] = data?.sha256String ?? "<missing>"
                    if data.map(ModuleSyncPlanner.normalizedPublishedData) != file.data { changed.append(file.name) }
                }
                previews.append(PublishPreview(destination: .local, targetDescription: settings.localModuleDirectory,
                    activeFiles: prepared.files.map(\.name), changedFiles: changed, deletedFiles: []))
            }
        }
        for index in previews.indices {
            let output = files[previews[index].destination] ?? []
            previews[index].issues = await Task.detached { ModuleLintPlanner.check(files: output) }.value
        }
        guard Self.samePublishConfiguration(settings, originalSettings), localChangeGeneration == generation else { throw PreviewContentSaveError.changed }
        try checkCurrentWorkCancellation()
        let ticket = WebPublishTicket(scope: scope, moduleIDs: ids, retryAttemptID: request.retryAttemptID,
            generation: generation, settings: settings, files: files, previews: previews,
            pathPlan: pathPlan, gitHubHead: head, localHashes: localHashes, retainsForNativeUI: retainsForNativeUI)
        try webActionTickets.store(ticket)
        return ticket.payload
    }

    func confirmWebPublish(token: UUID) async throws -> WebPublishResultPayload {
        guard !isWorking else { throw PreviewContentSaveError.busy }
        let ticket = try webActionTickets.consumePublish(token)
        beginWork(.confirmingPublish)
        do {
            guard Self.samePublishConfiguration(settings, ticket.settings), localChangeGeneration == ticket.generation else { throw PreviewContentSaveError.changed }
            for destination in ticket.files.keys {
                try validateWebPublishTarget(destination)
                let current = try await webPublishFiles(scope: ticket.scope, moduleIDs: ticket.moduleIDs, destination: destination)
                guard Self.publishFingerprint(current.files) == Self.publishFingerprint(ticket.files[destination] ?? []),
                      current.pathPlan == (destination == .gitHub ? ticket.pathPlan : nil) else {
                    throw PreviewContentSaveError.changed
                }
            }
            if let expectedHead = ticket.gitHubHead {
                let report = try await githubClient.previewPublish(files: ticket.files[.gitHub] ?? [],
                    deleting: ticket.pathPlan?.stalePaths ?? [], settings: settings.github,
                    token: ensureGitHubTokenLoaded(showStatusMessage: false))
                guard report.baseCommitSHA == expectedHead else { throw PreviewContentSaveError.changed }
            }
            for (path, expectedHash) in ticket.localHashes {
                let data = try await fileStore.readPublishedFile(relativePath: path, rootDirectoryPath: settings.localModuleDirectory)
                guard (data?.sha256String ?? "<missing>") == expectedHash else { throw PreviewContentSaveError.changed }
            }
            guard Self.samePublishConfiguration(settings, ticket.settings), localChangeGeneration == ticket.generation else { throw PreviewContentSaveError.changed }
            try checkCurrentWorkCancellation()
            if ticket.scope == "githubAll" {
                let report = try await publishAllInternal(allowDeleting: true, reviewed: ticket)
                recordGitHubPublish(report)
                statusMessage = GitHubPublishPlanner.reportStatus(for: .publishAll, report: report, scopeTitle: githubPublishPlan.scopeTitle)
                endWork(.confirmingPublish)
                return WebPublishResultPayload(ok: true, message: statusMessage, attempt: nil)
            }
            let attempt: SelectedPublishAttempt
            if let retryID = ticket.retryAttemptID {
                guard let previous = selectedPublishAttempt, previous.id == retryID,
                      previous.retryDestinations == Set(ticket.files.keys) else { throw PreviewContentSaveError.changed }
                attempt = previous
            } else {
                attempt = SelectedPublishAttempt(moduleIDs: ticket.moduleIDs, results: PublishDestination.allCases.compactMap {
                    ticket.files[$0] == nil ? nil : PublishTargetResult(destination: $0, target: selectedPublishTarget($0))
                })
            }
            endWork(.confirmingPublish)
            let success = await runSelectedPublish(attempt, destinations: Set(ticket.files.keys), reviewed: ticket)
            return WebPublishResultPayload(ok: success, message: statusMessage, attempt: selectedPublishAttempt)
        } catch {
            endWork(.confirmingPublish)
            throw error
        }
    }

    private func validateWebPublishTarget(_ destination: PublishDestination) throws {
        switch destination {
        case .local:
            guard settings.publishToLocal, !settings.localModuleDirectory.isEmpty else {
                throw RelayError.invalidOutput("本地发布未开启或目录未配置，请先在原生设置中配置。")
            }
        case .gitHub:
            guard settings.publishToGitHub, settings.github.isConfigured else {
                throw RelayError.invalidOutput("GitHub 发布未开启或仓库未配置，请先在原生设置中配置。")
            }
        }
    }

    private func webPublishFiles(scope: String, moduleIDs: Set<UUID>, destination: PublishDestination) async throws -> (files: [PublishFile], pathPlan: GitHubPublishedPathPlan?) {
        let plan = scope == "githubAll" ? githubPublishPlan : PublishCoordinator.selectedPlan(
            modules: modules, moduleIDs: moduleIDs, combinedModuleEnabled: settings.combinedModuleEnabled, destination: destination)
        try GitHubPublishPlanner.validatePublishableSelection(plan)
        let combined = scope == "githubAll" && settings.combinedModuleEnabled ? try await fileStore.readCombined() : nil
        let files = try await publishedFiles(plan: plan, combinedData: combined, includeAssets: true, destination: destination)
        let issues = await Task.detached { ModuleLintPlanner.check(files: files, ownedModuleIDs: plan.assetModuleIDs) }.value
        try ModuleLintPlanner.throwIfBlocking(issues)
        let paths = scope == "githubAll" ? GitHubPublishPlanner.pathPlan(currentPaths: files.map(\.name), settings: settings.github,
            knownRepositoryKey: settings.githubPublishedRepositoryKey, knownPublishedPaths: settings.githubPublishedFilePaths) : nil
        return (files, paths)
    }

    static func samePublishConfiguration(_ lhs: AppSettings, _ rhs: AppSettings) -> Bool {
        lhs.publishToLocal == rhs.publishToLocal && lhs.publishToGitHub == rhs.publishToGitHub &&
        lhs.localModuleDirectory == rhs.localModuleDirectory && lhs.github == rhs.github &&
        lhs.combinedModuleEnabled == rhs.combinedModuleEnabled && lhs.combinedModuleFileName == rhs.combinedModuleFileName &&
        lhs.localPublishedRootDirectory == rhs.localPublishedRootDirectory && lhs.localPublishedFilePaths == rhs.localPublishedFilePaths &&
        lhs.githubPublishedRepositoryKey == rhs.githubPublishedRepositoryKey && lhs.githubPublishedFilePaths == rhs.githubPublishedFilePaths
    }

    private static func publishFingerprint(_ files: [PublishFile]) -> String {
        Data(files.sorted { $0.name < $1.name }.map { "\($0.name.utf8.count):\($0.name):\($0.data.sha256String)" }.joined(separator: "\n").utf8).sha256String
    }
}
