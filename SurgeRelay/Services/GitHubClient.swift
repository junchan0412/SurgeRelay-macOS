import Foundation

actor GitHubClient {
    private enum PublishAttemptError: Error {
        case verificationFailed
    }

    private struct RemoteTreeSnapshot {
        let headCommitSHA: String
        let baseTreeSHA: String
        let blobsByRepositoryPath: [String: String]
        let moduleDirectories: [String]
        let isTruncated: Bool
    }
    private struct RemotePublishDiff {
        let snapshot: RemoteTreeSnapshot
        let changedFiles: [PublishFile]
        let deletedFiles: [String]
    }

    private let restClient: GitHubRESTClient

    init(session: URLSession = .shared) {
        restClient = GitHubRESTClient(session: session)
    }

    func test(settings: GitHubSettings, token: String) async throws -> Bool {
        guard settings.isConfigured else { throw RelayError.githubNotConfigured }
        return try await restClient.repositoryIsPrivate(settings: settings, token: token)
    }

    func listDirectories(settings: GitHubSettings, token: String) async throws -> [String] {
        guard settings.isConfigured else { throw RelayError.githubNotConfigured }
        let snapshot = try await remoteTreeSnapshot(settings: settings, token: token)
        return snapshot.moduleDirectories
    }

    func previewPublish(
        files: [PublishFile],
        deleting obsoleteFileNames: [String] = [],
        settings: GitHubSettings,
        token: String
    ) async throws -> PublishReport {
        guard settings.isConfigured else { throw RelayError.githubNotConfigured }
        guard !token.isEmpty else { throw RelayError.githubTokenMissing }
        guard !files.isEmpty || !obsoleteFileNames.isEmpty else { throw RelayError.noFilesToPublish }
        try GitHubRepositoryPath.validateUniqueRepositoryPaths(files, settings: settings)

        let diff = try await publishDiff(
            files: files,
            deleting: obsoleteFileNames,
            settings: settings,
            token: token
        )
        return PublishReport(
            publishedFiles: diff.changedFiles.map(\.name),
            deletedFiles: diff.deletedFiles
        )
    }

    func publish(
        files: [PublishFile],
        deleting obsoleteFileNames: [String] = [],
        settings: GitHubSettings,
        token: String
    ) async throws -> PublishReport {
        guard settings.isConfigured else { throw RelayError.githubNotConfigured }
        guard !token.isEmpty else { throw RelayError.githubTokenMissing }
        guard !files.isEmpty || !obsoleteFileNames.isEmpty else { throw RelayError.noFilesToPublish }
        try GitHubRepositoryPath.validateUniqueRepositoryPaths(files, settings: settings)

        var retriedAfterConflict = false
        for attempt in 0..<2 {
            do {
                var report = try await publishOnce(
                    files: files,
                    deleting: obsoleteFileNames,
                    settings: settings,
                    token: token
                )
                report.retriedAfterConflict = retriedAfterConflict
                return report
            } catch {
                guard attempt == 0, isRetryablePublishError(error) else {
                    if error is PublishAttemptError {
                        throw RelayError.invalidOutput("GitHub 提交后引用校验失败，未确认发布成功。")
                    }
                    throw error
                }
                if let relayError = error as? RelayError,
                   Self.isReferenceUpdateConflict(relayError) {
                    retriedAfterConflict = true
                }
                try Task.checkCancellation()
                continue
            }
        }

        throw RelayError.invalidOutput("GitHub 发布重试失败。")
    }

    private func publishOnce(
        files: [PublishFile],
        deleting obsoleteFileNames: [String],
        settings: GitHubSettings,
        token: String
    ) async throws -> PublishReport {
        let diff = try await publishDiff(
            files: files,
            deleting: obsoleteFileNames,
            settings: settings,
            token: token
        )
        let snapshot = diff.snapshot
        let changedFiles = diff.changedFiles
        let deletedFiles = diff.deletedFiles
        guard !changedFiles.isEmpty || !deletedFiles.isEmpty else {
            return PublishReport(publishedFiles: [])
        }

        var entries: [GitHubAPI.TreeEntry] = []
        for file in changedFiles {
            try Task.checkCancellation()
            let blob: GitHubAPI.BlobResponse = try await restClient.requestJSON(
                path: "git/blobs",
                method: "POST",
                body: GitHubAPI.BlobRequest(content: file.data.base64EncodedString()),
                settings: settings,
                token: token
            )
            entries.append(GitHubAPI.TreeEntry(
                path: GitHubRepositoryPath.repositoryPath(for: file.name, settings: settings),
                sha: blob.sha
            ))
        }
        for fileName in deletedFiles {
            entries.append(GitHubAPI.TreeEntry(
                deletingPath: GitHubRepositoryPath.repositoryPath(for: fileName, settings: settings)
            ))
        }
        let tree: GitHubAPI.TreeResponse = try await restClient.requestJSON(
            path: "git/trees",
            method: "POST",
            body: GitHubAPI.TreeRequest(baseTree: snapshot.baseTreeSHA, tree: entries),
            settings: settings,
            token: token
        )
        let commit: GitHubAPI.CommitResponse = try await restClient.requestJSON(
            path: "git/commits",
            method: "POST",
            body: GitHubAPI.CommitRequest(
                message: GitHubRepositoryPath.commitMessage(
                    changedCount: changedFiles.count,
                    deletedCount: deletedFiles.count
                ),
                tree: tree.sha,
                parents: [snapshot.headCommitSHA]
            ),
            settings: settings,
            token: token
        )
        let branch = GitHubRepositoryPath.encodedPathComponent(settings.branch)
        let updatedReference: GitHubAPI.ReferenceResponse = try await restClient.requestJSON(
            path: "git/refs/heads/\(branch)",
            method: "PATCH",
            body: GitHubAPI.UpdateReferenceRequest(sha: commit.sha),
            settings: settings,
            token: token
        )
        try Task.checkCancellation()
        guard updatedReference.object.sha == commit.sha else {
            throw PublishAttemptError.verificationFailed
        }
        return PublishReport(
            publishedFiles: changedFiles.map(\.name),
            deletedFiles: deletedFiles,
            commitSHA: commit.sha
        )
    }

    private func isRetryablePublishError(_ error: Error) -> Bool {
        if error is PublishAttemptError { return true }
        if let relayError = error as? RelayError {
            return Self.isReferenceUpdateConflict(relayError)
        }
        return false
    }

    private static func isReferenceUpdateConflict(_ error: RelayError) -> Bool {
        guard case let .httpFailure(status, message) = error,
              status == 409 || status == 422 else { return false }
        let lowercased = message.lowercased()
        return lowercased.contains("reference update failed")
            || lowercased.contains("not a fast forward")
            || lowercased.contains("non-fast-forward")
            || lowercased.contains("cannot lock ref")
            || lowercased.contains("sha does not match")
    }

    private func publishDiff(
        files: [PublishFile],
        deleting obsoleteFileNames: [String],
        settings: GitHubSettings,
        token: String
    ) async throws -> RemotePublishDiff {
        let snapshot = try await remoteTreeSnapshot(settings: settings, token: token)
        let currentFileNames = Set(files.map(\.name))
        var changedFiles: [PublishFile] = []
        var deletedFiles: [String] = []
        if snapshot.isTruncated {
            for file in files {
                try Task.checkCancellation()
                let sha = try await restClient.existingSHA(fileName: file.name, settings: settings, token: token)
                if sha != file.data.gitBlobSHA1 { changedFiles.append(file) }
            }
            for fileName in Set(obsoleteFileNames).sorted() where !currentFileNames.contains(fileName) {
                try Task.checkCancellation()
                if try await restClient.existingSHA(fileName: fileName, settings: settings, token: token) != nil {
                    deletedFiles.append(fileName)
                }
            }
        } else {
            for file in files {
                try Task.checkCancellation()
                let path = GitHubRepositoryPath.repositoryPath(for: file.name, settings: settings)
                if snapshot.blobsByRepositoryPath[path] != file.data.gitBlobSHA1 {
                    changedFiles.append(file)
                }
            }
            for fileName in Set(obsoleteFileNames).sorted() where !currentFileNames.contains(fileName) {
                try Task.checkCancellation()
                let path = GitHubRepositoryPath.repositoryPath(for: fileName, settings: settings)
                if snapshot.blobsByRepositoryPath[path] != nil {
                    deletedFiles.append(fileName)
                }
            }
        }
        return RemotePublishDiff(
            snapshot: snapshot,
            changedFiles: changedFiles,
            deletedFiles: deletedFiles
        )
    }

    private func remoteTreeSnapshot(settings: GitHubSettings, token: String) async throws -> RemoteTreeSnapshot {
        let branch = GitHubRepositoryPath.encodedPathComponent(settings.branch)
        let reference: GitHubAPI.ReferenceResponse = try await restClient.requestJSON(
            path: "git/ref/heads/\(branch)",
            method: "GET",
            settings: settings,
            token: token
        )
        let headCommit: GitHubAPI.CommitResponse = try await restClient.requestJSON(
            path: "git/commits/\(reference.object.sha)",
            method: "GET",
            settings: settings,
            token: token
        )
        let tree: GitHubAPI.RecursiveTreeResponse = try await restClient.requestJSON(
            path: "git/trees/\(headCommit.tree.sha)?recursive=1",
            method: "GET",
            settings: settings,
            token: token
        )
        return RemoteTreeSnapshot(
            headCommitSHA: headCommit.sha,
            baseTreeSHA: headCommit.tree.sha,
            blobsByRepositoryPath: GitHubRepositoryPath.blobsByRepositoryPath(from: tree.tree),
            moduleDirectories: GitHubRepositoryPath.moduleDirectories(from: tree.tree, settings: settings),
            isTruncated: tree.truncated == true
        )
    }

}
