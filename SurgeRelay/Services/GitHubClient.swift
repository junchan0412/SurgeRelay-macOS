import Foundation

actor GitHubClient {
    private struct ExistingContent: Decodable { let sha: String }
    private struct GitHubMessage: Decodable { let message: String }
    private struct RepositoryMetadata: Decodable {
        let isPrivate: Bool
        private enum CodingKeys: String, CodingKey { case isPrivate = "private" }
    }
    private struct RepositoryContentItem: Decodable {
        let name: String
        let type: String
    }
    private struct GitObject: Codable { let sha: String }
    private struct ReferenceResponse: Decodable { let object: GitObject }
    private struct CommitResponse: Decodable {
        let sha: String
        let tree: GitObject
    }
    private struct BlobRequest: Encodable {
        let content: String
        let encoding = "base64"
    }
    private struct BlobResponse: Decodable { let sha: String }
    private struct TreeEntry: Encodable {
        let path: String
        let mode: String?
        let type: String?
        let sha: String?

        init(path: String, sha: String) {
            self.path = path
            mode = "100644"
            type = "blob"
            self.sha = sha
        }

        init(deletingPath path: String) {
            self.path = path
            mode = nil
            type = nil
            sha = nil
        }

        private enum CodingKeys: String, CodingKey { case path, mode, type, sha }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(mode, forKey: .mode)
            try container.encodeIfPresent(type, forKey: .type)
            if let sha {
                try container.encode(sha, forKey: .sha)
            } else {
                try container.encodeNil(forKey: .sha)
            }
        }
    }
    private struct TreeRequest: Encodable {
        let baseTree: String
        let tree: [TreeEntry]
        private enum CodingKeys: String, CodingKey { case baseTree = "base_tree", tree }
    }
    private struct TreeResponse: Decodable { let sha: String }
    private struct CommitRequest: Encodable {
        let message: String
        let tree: String
        let parents: [String]
    }
    private struct UpdateReferenceRequest: Encodable {
        let sha: String
        let force = false
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
        return try JSONDecoder().decode(RepositoryMetadata.self, from: data).isPrivate
    }

    func listDirectories(settings: GitHubSettings, token: String) async throws -> [String] {
        guard settings.isConfigured else { throw RelayError.githubNotConfigured }
        var components = URLComponents(url: try contentsURL(settings: settings), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "ref", value: settings.branch)]
        guard let url = components?.url else { throw RelayError.githubNotConfigured }

        var request = URLRequest(url: url, timeoutInterval: 30)
        applyHeaders(to: &request, token: token)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return [] }
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(GitHubMessage.self, from: data).message)
                ?? "GitHub 目录查询失败。"
            throw RelayError.httpFailure(status: status, message: message)
        }
        return try JSONDecoder().decode([RepositoryContentItem].self, from: data)
            .filter { $0.type == "dir" }
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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

        var changedFiles: [PublishFile] = []
        for file in files {
            try Task.checkCancellation()
            let sha = try await existingSHA(fileName: file.name, settings: settings, token: token)
            if sha != file.data.gitBlobSHA1 { changedFiles.append(file) }
        }

        let currentFileNames = Set(files.map(\.name))
        var deletedFiles: [String] = []
        for fileName in Set(obsoleteFileNames).sorted() where !currentFileNames.contains(fileName) {
            try Task.checkCancellation()
            if try await existingSHA(fileName: fileName, settings: settings, token: token) != nil {
                deletedFiles.append(fileName)
            }
        }
        guard !changedFiles.isEmpty || !deletedFiles.isEmpty else {
            return PublishReport(publishedFiles: [])
        }

        let branch = encodedPathComponent(settings.branch)
        let reference: ReferenceResponse = try await requestJSON(
            path: "git/ref/heads/\(branch)",
            method: "GET",
            settings: settings,
            token: token
        )
        let headCommit: CommitResponse = try await requestJSON(
            path: "git/commits/\(reference.object.sha)",
            method: "GET",
            settings: settings,
            token: token
        )
        var entries: [TreeEntry] = []
        for file in changedFiles {
            try Task.checkCancellation()
            let blob: BlobResponse = try await requestJSON(
                path: "git/blobs",
                method: "POST",
                body: BlobRequest(content: file.data.base64EncodedString()),
                settings: settings,
                token: token
            )
            entries.append(TreeEntry(path: repositoryPath(for: file.name, settings: settings), sha: blob.sha))
        }
        for fileName in deletedFiles {
            entries.append(TreeEntry(deletingPath: repositoryPath(for: fileName, settings: settings)))
        }
        let tree: TreeResponse = try await requestJSON(
            path: "git/trees",
            method: "POST",
            body: TreeRequest(baseTree: headCommit.tree.sha, tree: entries),
            settings: settings,
            token: token
        )
        let commit: CommitResponse = try await requestJSON(
            path: "git/commits",
            method: "POST",
            body: CommitRequest(
                message: commitMessage(changedCount: changedFiles.count, deletedCount: deletedFiles.count),
                tree: tree.sha,
                parents: [headCommit.sha]
            ),
            settings: settings,
            token: token
        )
        let _: ReferenceResponse = try await requestJSON(
            path: "git/refs/heads/\(branch)",
            method: "PATCH",
            body: UpdateReferenceRequest(sha: commit.sha),
            settings: settings,
            token: token
        )
        try Task.checkCancellation()
        return PublishReport(
            publishedFiles: changedFiles.map(\.name),
            deletedFiles: deletedFiles,
            commitSHA: commit.sha
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
            let message = (try? JSONDecoder().decode(GitHubMessage.self, from: data).message)
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
            let message = (try? JSONDecoder().decode(GitHubMessage.self, from: data).message) ?? "GitHub 查询失败。"
            throw RelayError.httpFailure(status: status, message: message)
        }
        return try JSONDecoder().decode(ExistingContent.self, from: data).sha
    }

    private func apiURL(settings: GitHubSettings, fileName: String?) throws -> URL {
        var path = "https://api.github.com/repos/\(settings.owner)/\(settings.repository)"
        if let fileName {
            path += "/contents/\(encodedRepositoryPath(for: fileName, settings: settings))"
        }
        guard let url = URL(string: path) else { throw RelayError.githubNotConfigured }
        return url
    }

    private func contentsURL(settings: GitHubSettings) throws -> URL {
        var path = "https://api.github.com/repos/\(settings.owner)/\(settings.repository)/contents"
        let directory = encodedRepositoryDirectory(settings: settings)
        if !directory.isEmpty { path += "/\(directory)" }
        guard let url = URL(string: path) else { throw RelayError.githubNotConfigured }
        return url
    }

    private func apiURL(settings: GitHubSettings, suffix: String) throws -> URL {
        guard let url = URL(string: "https://api.github.com/repos/\(settings.owner)/\(settings.repository)/\(suffix)") else {
            throw RelayError.githubNotConfigured
        }
        return url
    }

    private func repositoryPath(for fileName: String, settings: GitHubSettings) -> String {
        let directory = settings.directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return [directory, fileName].filter { !$0.isEmpty }.joined(separator: "/")
    }

    private func commitMessage(changedCount: Int, deletedCount: Int) -> String {
        switch (changedCount, deletedCount) {
        case (_, 0):
            "Update \(changedCount) files via Surge Relay"
        case (0, _):
            "Remove \(deletedCount) stale files via Surge Relay"
        default:
            "Update \(changedCount) files and remove \(deletedCount) stale files via Surge Relay"
        }
    }

    private func encodedRepositoryPath(for fileName: String, settings: GitHubSettings) -> String {
        repositoryPath(for: fileName, settings: settings)
            .split(separator: "/")
            .map { encodedPathComponent(String($0)) }
            .joined(separator: "/")
    }

    private func encodedRepositoryDirectory(settings: GitHubSettings) -> String {
        settings.directory
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .map { encodedPathComponent(String($0)) }
            .joined(separator: "/")
    }

    private func encodedPathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
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
