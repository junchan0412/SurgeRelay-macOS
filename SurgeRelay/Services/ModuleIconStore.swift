import Foundation

actor ModuleIconStore {
    private let httpClient: BoundedHTTPClient
    nonisolated let cacheDirectory: URL

    init(cacheDirectory: URL = PersistenceStore.cacheDirectoryURL, session: URLSession = .shared) {
        self.cacheDirectory = cacheDirectory
        httpClient = BoundedHTTPClient(maximumResponseSize: 5 * 1024 * 1024, configuration: session.configuration)
    }
    nonisolated static var directoryURL: URL {
        PersistenceStore.cacheDirectoryURL
            .appending(path: "Icons", directoryHint: .isDirectory)
    }

    nonisolated static func cachedURL(for moduleID: UUID, cacheDirectory: URL? = nil) -> URL {
        (cacheDirectory.map { $0.appending(path: "Icons", directoryHint: .isDirectory) } ?? directoryURL)
            .appending(path: moduleID.uuidString.lowercased())
    }

    private nonisolated func legacyCachedURL(for moduleID: UUID) -> URL {
        cacheDirectory.appending(path: "Icons", directoryHint: .isDirectory)
            .appending(path: moduleID.uuidString.lowercased() + ".image")
    }

    func cacheIcon(from url: URL, for moduleID: UUID, force: Bool = false) async throws {
        if !force, FileManager.default.fileExists(atPath: Self.cachedURL(for: moduleID, cacheDirectory: cacheDirectory).path) {
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30)
        request.setValue("SurgeRelay/2.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await httpClient.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), !data.isEmpty, data.count <= 5 * 1024 * 1024 else {
            throw RelayError.httpFailure(status: status, message: "模块图标下载失败。")
        }
        try FileManager.default.createDirectory(at: cacheDirectory.appending(path: "Icons", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try data.write(to: Self.cachedURL(for: moduleID, cacheDirectory: cacheDirectory), options: .atomic)
        try? FileManager.default.removeItem(at: legacyCachedURL(for: moduleID))
    }

    func removeIcon(for moduleID: UUID) throws {
        let url = Self.cachedURL(for: moduleID, cacheDirectory: cacheDirectory)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let legacyURL = legacyCachedURL(for: moduleID)
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            try FileManager.default.removeItem(at: legacyURL)
        }
    }
}
