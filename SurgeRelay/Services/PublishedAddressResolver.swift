import Foundation

enum PublishedAddressResolver {
    static func githubURL(for relativePath: String, settings: AppSettings) -> URL? {
        guard settings.publishToGitHub else { return nil }
        return settings.github.publicURL(for: relativePath)
    }

    static func standaloneURL(for module: RelayModule, settings: AppSettings) -> URL? {
        guard module.publishesStandalone, module.storageLocation == .gitHub else { return nil }
        return githubURL(for: module.publishedRelativePath, settings: settings)
    }

    static func combinedGitHubURL(settings: AppSettings) -> URL? {
        guard settings.combinedModuleEnabled else { return nil }
        return githubURL(
            for: FilenameSanitizer.sgmoduleName(from: settings.combinedModuleFileName),
            settings: settings
        )
    }

    static func combinedLocalFileURL(settings: AppSettings) -> URL? {
        guard settings.combinedModuleEnabled, settings.publishToLocal else { return nil }
        let directory = settings.localModuleDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else { return nil }
        return URL(filePath: directory, directoryHint: .isDirectory)
            .appending(path: FilenameSanitizer.sgmoduleName(from: settings.combinedModuleFileName))
    }
}
