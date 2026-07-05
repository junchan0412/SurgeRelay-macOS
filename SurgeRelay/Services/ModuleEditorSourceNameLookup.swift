import Foundation

enum ModuleEditorSourceNameLookup {
    private static let userAgent = "Surge Relay"

    static func autofillName(from sourceURL: String) async -> String? {
        await autofillName(from: sourceURL, fetchData: defaultFetchData(for:))
    }

    static func autofillName(
        from sourceURL: String,
        fetchData: (URLRequest) async throws -> Data
    ) async -> String? {
        guard let url = remoteURL(from: sourceURL) else { return nil }
        let fallback = fallbackName(from: sourceURL)
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        guard let data = try? await fetchData(request),
              let content = String(data: data, encoding: .utf8),
              let name = ModuleMetadataParser.displayName(in: content) else {
            return fallback
        }
        return name
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
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }
}
