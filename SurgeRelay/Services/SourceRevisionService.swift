import Foundation

actor SourceRevisionService {
    private let httpClient: BoundedHTTPClient
    private static let maximumSourceSize = 20 * 1024 * 1024

    init(session: URLSession = .shared) {
        httpClient = BoundedHTTPClient(configuration: session.configuration)
    }

    func check(_ module: RelayModule, hasCache: Bool = true) async throws -> SourceRevisionResult {
        try Task.checkCancellation()
        guard let url = URL(string: module.updateSourceURL) else { throw RelayError.invalidSourceURL }
        if url.isFileURL {
            return revision(for: try Self.readLocalSource(url), module: module, hasCache: hasCache)
        }
        guard ["http", "https"].contains(url.scheme?.lowercased()) else { throw RelayError.invalidSourceURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 45)
        request.setValue("SurgeRelay/2.0", forHTTPHeaderField: "User-Agent")
        if hasCache, module.sourceContentHash != nil {
            if let etag = module.sourceETag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let modified = module.sourceLastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        }
        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RelayError.invalidOutput("来源没有返回有效的 HTTP 响应。")
        }
        if http.statusCode == 304, hasCache, let hash = module.sourceContentHash {
            return .unchanged(SourceRevisionSnapshot(
                etag: http.value(forHTTPHeaderField: "ETag") ?? module.sourceETag,
                lastModified: http.value(forHTTPHeaderField: "Last-Modified") ?? module.sourceLastModified,
                contentHash: hash,
                checkedAt: .now
            ))
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8).map { String($0.prefix(240)) } ?? "来源检查失败。"
            throw RelayError.httpFailure(status: http.statusCode, message: message)
        }
        guard !data.isEmpty else { throw RelayError.invalidOutput("来源文件为空。") }
        return revision(for: data, module: module, hasCache: hasCache, response: http)
    }

    nonisolated static func readLocalSource(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maximumSourceSize else {
            throw RelayError.invalidOutput("来源文件为空或超过 20 MB。")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty, data.count <= maximumSourceSize else {
            throw RelayError.invalidOutput("来源文件为空或超过 20 MB。")
        }
        return data
    }

    private func revision(for data: Data, module: RelayModule, hasCache: Bool, response: HTTPURLResponse? = nil) -> SourceRevisionResult {
        let snapshot = SourceRevisionSnapshot(
            etag: response?.value(forHTTPHeaderField: "ETag"),
            lastModified: response?.value(forHTTPHeaderField: "Last-Modified"),
            contentHash: data.sha256String,
            checkedAt: .now,
            data: data
        )
        return hasCache && snapshot.contentHash == module.sourceContentHash ? .unchanged(snapshot) : .changed(snapshot)
    }
}
