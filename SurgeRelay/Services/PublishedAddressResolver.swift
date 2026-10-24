import Foundation

enum PublishedAddressResolver {
    static func githubURL(for relativePath: String, settings: AppSettings) -> URL? {
        guard settings.publishToGitHub else { return nil }
        return settings.github.publicURL(for: relativePath)
    }

    static func standaloneURL(for module: RelayModule, settings: AppSettings) -> URL? {
        guard module.hasGitHubStorageTarget else { return nil }
        return githubURL(for: module.publishedRelativePath, settings: settings)
    }

}
