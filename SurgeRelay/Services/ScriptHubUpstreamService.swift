import Foundation

actor ScriptHubUpstreamService {
    private let session: URLSession
    private let maximumDownloadSize = 10 * 1024 * 1024

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchManagedModule(
        from source: String,
        previousRevision: String?,
        previousUpstreamRevision: String? = nil,
        previousScriptHashes: [String: String] = [:]
    ) async throws -> UpstreamUpdateResult {
        let upstreamSource = try PinnedScriptHubSource(source)
        let url = upstreamSource.moduleURL
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        request.setValue("SurgeRelay/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await loadData(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(status) else {
            throw RelayError.httpFailure(status: status, message: String(body.prefix(240)))
        }
        guard body.contains("script.hub"), body.contains("script-path=") else {
            throw RelayError.invalidOutput("上游文件不是可识别的 Script-Hub Surge 模块。")
        }

        var revisionMaterial = data
        var scripts: [String: Data] = [:]
        var scriptHashes: [String: String] = [:]
        for scriptURL in try scriptURLs(in: body, source: upstreamSource) {
            var scriptRequest = URLRequest(url: scriptURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
            scriptRequest.setValue("SurgeRelay/0.1", forHTTPHeaderField: "User-Agent")
            let (scriptData, scriptResponse) = try await loadData(for: scriptRequest)
            let scriptStatus = (scriptResponse as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(scriptStatus), !scriptData.isEmpty else {
                throw RelayError.httpFailure(status: scriptStatus, message: "无法检查上游脚本 \(scriptURL.lastPathComponent)。")
            }
            revisionMaterial.append(scriptData)
            scripts[scriptURL.lastPathComponent] = scriptData
            scriptHashes[scriptURL.lastPathComponent] = scriptData.sha256String
        }

        let revision = String(revisionMaterial.sha256String.prefix(12))
        if previousUpstreamRevision == upstreamSource.revision,
           !previousScriptHashes.isEmpty,
           previousScriptHashes != scriptHashes {
            throw RelayError.invalidOutput("固定 Script-Hub revision 的脚本 hash 已变化，已拒绝更新。")
        }
        guard scripts["Rewrite-Parser.js"] != nil else {
            throw RelayError.invalidOutput("上游模块没有引用 Rewrite-Parser.js。")
        }
        return UpstreamUpdateResult(
            revision: revision,
            changed: revision != previousRevision,
            scripts: scripts,
            sourceDescription: upstreamSource.description,
            upstreamRevision: upstreamSource.revision,
            scriptHashes: scriptHashes
        )
    }

    private func loadData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await session.data(for: request)
        if response.expectedContentLength > maximumDownloadSize || data.count > maximumDownloadSize {
            throw RelayError.invalidOutput("Script-Hub 上游下载超过 10 MB 限制。")
        }
        return (data, response)
    }

    private func scriptURLs(in module: String, source: PinnedScriptHubSource) throws -> [URL] {
        let pattern = #"script-path=(https://raw\.githubusercontent\.com/[^,\s?]+)(?:\?[^,\s]*)?"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = expression.matches(in: module, range: NSRange(module.startIndex..., in: module))
        var seen = Set<String>()
        return try matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: module) else { return nil }
            let value = String(module[range])
            guard seen.insert(value).inserted else { return nil }
            return try source.pinnedScriptURL(from: value)
        }
    }

}

private struct PinnedScriptHubSource {
    let owner: String
    let repository: String
    let revision: String
    let modulePath: String
    let moduleURL: URL

    init(_ source: String) throws {
        guard let url = URL(string: source.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "raw.githubusercontent.com" else {
            throw RelayError.invalidSourceURL
        }
        let components = url.path.split(separator: "/").map(String.init)
        guard components.count >= 4 else { throw RelayError.invalidSourceURL }
        owner = components[0]
        repository = components[1]
        revision = components[2]
        modulePath = components.dropFirst(3).joined(separator: "/")
        guard owner == "Script-Hub-Org",
              repository == "Script-Hub",
              modulePath == "modules/script-hub.surge.sgmodule",
              Self.isPinnedRevision(revision) else {
            throw RelayError.invalidOutput("Script-Hub 上游必须使用 Script-Hub-Org/Script-Hub 的固定 tag 或 commit，不能使用 main/master/HEAD。")
        }
        moduleURL = url
    }

    var description: String {
        "\(owner)/\(repository)@\(revision)"
    }

    func pinnedScriptURL(from value: String) throws -> URL {
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "raw.githubusercontent.com" else {
            throw RelayError.invalidSourceURL
        }
        let components = url.path.split(separator: "/").map(String.init)
        guard components.count >= 4,
              components[0] == owner,
              components[1] == repository else {
            throw RelayError.invalidOutput("Script-Hub 模块引用了非固定仓库脚本：\(value)")
        }
        let scriptPath = components.dropFirst(3).joined(separator: "/")
        var pinned = URLComponents()
        pinned.scheme = "https"
        pinned.host = "raw.githubusercontent.com"
        pinned.path = "/" + [owner, repository, revision, scriptPath].joined(separator: "/")
        guard let pinnedURL = pinned.url else { throw RelayError.invalidSourceURL }
        return pinnedURL
    }

    private static func isPinnedRevision(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let floating = ["main", "master", "head"]
        if floating.contains(trimmed.lowercased()) { return false }
        if trimmed.range(of: #"^[A-Fa-f0-9]{40}$"#, options: .regularExpression) != nil {
            return true
        }
        return trimmed.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
    }
}
