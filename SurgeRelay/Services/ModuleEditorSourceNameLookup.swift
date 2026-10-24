import Foundation

enum ModuleEditorSourceNameLookup {
    private static let userAgent = "Surge Relay"

    static func autofillName(from sourceURL: String) async -> String? {
        await autofillName(from: sourceURL, fetchData: defaultFetchData(for:))
    }

    static func autofillName(
        from sourceURL: String,
        fetchData: @Sendable (URLRequest) async throws -> Data
    ) async -> String? {
        guard let url = URL(string: sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.isFileURL || remoteURL(from: sourceURL) != nil else { return nil }
        do {
            return try await resolvedName(from: sourceURL, fetchData: fetchData)
        } catch {
            return fallbackName(from: sourceURL)
        }
    }

    static func resolvedName(
        from sourceURL: String,
        fetchData: @Sendable (URLRequest) async throws -> Data = defaultFetchData(for:)
    ) async throws -> String {
        let source = ModuleMetadataParser.scriptHubSubscription(from: sourceURL)?.originalURL ?? sourceURL
        guard let url = URL(string: source.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.isFileURL || remoteURL(from: source) != nil else {
            throw BoundedRemoteFetchError.invalidSourceURL
        }
        if url.isFileURL {
            guard URL(string: sourceURL.trimmingCharacters(in: .whitespacesAndNewlines))?.isFileURL == true else {
                throw BoundedRemoteFetchError.invalidSourceURL
            }
            let data = try await Task.detached(priority: .utility) { try SourceRevisionService.readLocalSource(url) }.value
            return String(data: data, encoding: .utf8).flatMap { ModuleMetadataParser.displayName(in: $0) }
                ?? fallbackName(from: source)
        }
        let fallback = fallbackName(from: source)
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data = try await fetchData(request)
        return String(data: data, encoding: .utf8)
            .flatMap { ModuleMetadataParser.displayName(in: $0) } ?? fallback
    }

    static func remoteURL(from sourceURL: String) -> URL? {
        let trimmed = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              ["http", "https"].contains(url.scheme?.lowercased()) else {
            return nil
        }
        return url
    }

    static func fallbackName(from sourceURL: String) -> String {
        FilenameSanitizer.suggestedName(from: sourceURL.trimmingCharacters(in: .whitespacesAndNewlines))
            .replacingOccurrences(of: "-", with: " ")
    }

    private static func defaultFetchData(for request: URLRequest) async throws -> Data {
        try await BoundedRemoteDataFetcher.sourceNameLookup.data(for: request)
    }
}
