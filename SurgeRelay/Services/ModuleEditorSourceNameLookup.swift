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
        guard remoteURL(from: sourceURL) != nil else { return nil }
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
        guard let url = remoteURL(from: sourceURL) else {
            throw BoundedRemoteFetchError.invalidSourceURL
        }
        let fallback = fallbackName(from: sourceURL)
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
