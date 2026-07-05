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

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func test(settings: GitHubSettings, token: String) async throws -> Bool {
        guard settings.isConfigured else { throw RelayError.githubNotConfigured }
        let url = try apiURL(settings: settings, fileName: nil)
        var request = URLRequest(url: url, timeoutInterval: 30)
        applyHeaders(to: &request, token: token)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw RelayError.httpFailure(status: status, message: "无法访问该仓库。")
        }
        return try JSONDecoder().decode(GitHubAPI.RepositoryMetadata.self, from: data).isPrivate
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
            let blob: GitHubAPI.BlobResponse = try await requestJSON(
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
        let tree: GitHubAPI.TreeResponse = try await requestJSON(
            path: "git/trees",
            method: "POST",
            body: GitHubAPI.TreeRequest(baseTree: snapshot.baseTreeSHA, tree: entries),
            settings: settings,
            token: token
        )
        let commit: GitHubAPI.CommitResponse = try await requestJSON(
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
        let updatedReference: GitHubAPI.ReferenceResponse = try await requestJSON(
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
                let sha = try await existingSHA(fileName: file.name, settings: settings, token: token)
                if sha != file.data.gitBlobSHA1 { changedFiles.append(file) }
            }
            for fileName in Set(obsoleteFileNames).sorted() where !currentFileNames.contains(fileName) {
                try Task.checkCancellation()
                if try await existingSHA(fileName: fileName, settings: settings, token: token) != nil {
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
        let reference: GitHubAPI.ReferenceResponse = try await requestJSON(
            path: "git/ref/heads/\(branch)",
            method: "GET",
            settings: settings,
            token: token
        )
        let headCommit: GitHubAPI.CommitResponse = try await requestJSON(
            path: "git/commits/\(reference.object.sha)",
            method: "GET",
            settings: settings,
            token: token
        )
        let tree: GitHubAPI.RecursiveTreeResponse = try await requestJSON(
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

    private func requestJSON<Response: Decodable>(
        path: String,
        method: String,
        settings: GitHubSettings,
        token: String
    ) async throws -> Response {
        try await requestJSON(path: path, method: method, bodyData: nil, settings: settings, token: token)
    }

    private func requestJSON<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body,
        settings: GitHubSettings,
        token: String
    ) async throws -> Response {
        try await requestJSON(
            path: path,
            method: method,
            bodyData: JSONEncoder().encode(body),
            settings: settings,
            token: token
        )
    }

    private func requestJSON<Response: Decodable>(
        path: String,
        method: String,
        bodyData: Data?,
        settings: GitHubSettings,
        token: String
    ) async throws -> Response {
        let url = try apiURL(settings: settings, suffix: path)
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = method
        applyHeaders(to: &request, token: token)
        if let bodyData {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(GitHubAPI.Message.self, from: data).message)
                ?? String(data: data, encoding: .utf8) ?? "未知错误"
            throw RelayError.httpFailure(status: status, message: message)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func existingSHA(fileName: String, settings: GitHubSettings, token: String) async throws -> String? {
        var components = URLComponents(url: try apiURL(settings: settings, fileName: fileName), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "ref", value: settings.branch)]
        guard let url = components?.url else { throw RelayError.githubNotConfigured }
        var request = URLRequest(url: url, timeoutInterval: 30)
        applyHeaders(to: &request, token: token)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(GitHubAPI.Message.self, from: data).message) ?? "GitHub 查询失败。"
            throw RelayError.httpFailure(status: status, message: message)
        }
        return try JSONDecoder().decode(GitHubAPI.ExistingContent.self, from: data).sha
    }

    private func apiURL(settings: GitHubSettings, fileName: String?) throws -> URL {
        var path = "https://api.github.com/repos/\(try GitHubRepositoryValidator.validatedRepositoryPath(owner: settings.owner, repository: settings.repository))"
        if let fileName {
            path += "/contents/\(GitHubRepositoryPath.encodedRepositoryPath(for: fileName, settings: settings))"
        }
        guard let url = URL(string: path) else { throw RelayError.githubNotConfigured }
        return url
    }

    private func apiURL(settings: GitHubSettings, suffix: String) throws -> URL {
        let repositoryPath = try GitHubRepositoryValidator.validatedRepositoryPath(owner: settings.owner, repository: settings.repository)
        guard let url = URL(string: "https://api.github.com/repos/\(repositoryPath)/\(suffix)") else {
            throw RelayError.githubNotConfigured
        }
        return url
    }

    private func applyHeaders(to request: inout URLRequest, token: String) {
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("SurgeRelay/1.0", forHTTPHeaderField: "User-Agent")
    }
}
