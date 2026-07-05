import Foundation

@MainActor
extension AppModel {
    var combinedRawURL: URL? {
        PublishedAddressResolver.combinedGitHubURL(settings: settings)
    }

    var combinedLocalFileURL: URL? {
        PublishedAddressResolver.combinedLocalFileURL(settings: settings)
    }

    var latestGitHubPublish: GitHubPublishSnapshot? {
        GitHubPublishSnapshot.latest(in: updateHistory, settings: settings.github)
    }

    func rawURL(for module: RelayModule) -> URL? {
        PublishedAddressResolver.standaloneURL(for: module, settings: settings)
    }

    func previewContent(for module: RelayModule) async throws -> String {
        try await modulePreviewProvider.previewContent(for: module)
    }

    func moduleArgumentInfo(for module: RelayModule) async -> ModuleArgumentInfo {
        await modulePreviewProvider.moduleArgumentInfo(for: module)
    }

    func combinedPreviewContent() async throws -> String {
        try await modulePreviewProvider.combinedPreviewContent(
            combinedModuleEnabled: settings.combinedModuleEnabled
        )
    }

    func convertedPreviewContent(for module: RelayModule) async throws -> String {
        try await modulePreviewProvider.convertedPreviewContent(for: module)
    }
}
