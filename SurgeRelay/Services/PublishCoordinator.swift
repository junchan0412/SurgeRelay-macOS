import Foundation

struct PublishPlan: Equatable, Sendable {
    var standaloneModules: [RelayModule]
    var combinedModuleIDs: Set<UUID>

    var includesCombined: Bool {
        !combinedModuleIDs.isEmpty
    }

    var assetModuleIDs: Set<UUID> {
        Set(standaloneModules.map(\.id)).union(combinedModuleIDs)
    }

    var hasPublishableModuleSelection: Bool {
        !standaloneModules.isEmpty || includesCombined
    }

    var hasStandaloneModuleSelection: Bool {
        !standaloneModules.isEmpty
    }

    var scopeTitle: String {
        if includesCombined {
            return standaloneModules.isEmpty ? "总模块" : "总模块与独立模块"
        }
        return "独立模块"
    }
}

enum PublishCoordinator {
    static func repositoryKey(_ settings: GitHubSettings) -> String {
        [
            settings.owner,
            settings.repository,
            settings.branch,
            settings.directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        ]
        .joined(separator: "/")
    }

    static func retryPrefix(_ report: PublishReport) -> String {
        report.retriedAfterConflict ? "远端分支已更新并重新同步；" : ""
    }

    static func plan(
        modules: [RelayModule],
        combinedModuleEnabled: Bool,
        destination: PublishDestination
    ) -> PublishPlan {
        PublishPlan(
            standaloneModules: modules.filter {
                $0.publishesStandalone && $0.storageLocation.matches(destination)
            },
            combinedModuleIDs: Set(ModuleRefreshPlanner.combinedContributorModules(
                in: modules,
                combinedModuleEnabled: combinedModuleEnabled
            ).map(\.id))
        )
    }

    static func selectedPlan(
        modules: [RelayModule],
        moduleIDs: Set<UUID>,
        destination: PublishDestination
    ) -> PublishPlan {
        PublishPlan(
            standaloneModules: modules.filter {
                moduleIDs.contains($0.id) &&
                    $0.publishesStandalone &&
                    $0.storageLocation.matches(destination)
            },
            combinedModuleIDs: []
        )
    }

    static func shouldSkipStandaloneLocalExport(
        _ module: RelayModule,
        isLocalExport: Bool,
        localModuleDirectory: String
    ) -> Bool {
        guard isLocalExport,
              let sourceRelativePath = LocalSourcePathResolver.storageRelativePath(
                for: module,
                rootDirectoryPath: localModuleDirectory
              ) else {
            return false
        }
        return sourceRelativePath.lowercased() == module.publishedRelativePath.lowercased()
    }
}

private extension ModuleStorageLocation {
    func matches(_ destination: PublishDestination) -> Bool {
        switch (self, destination) {
        case (.local, .local), (.gitHub, .gitHub): true
        default: false
        }
    }
}

enum LocalSourcePathResolver {
    static func storageRelativePath(
        for module: RelayModule,
        rootDirectoryPath: String
    ) -> String? {
        if module.storageLocation == .local, let relativePath = module.localStorageRelativePath {
            return ModuleOutputFolder.normalized(relativePath)
        }
        return relativePath(forSourceURL: module.sourceURL, rootDirectoryPath: rootDirectoryPath)
    }

    static func fileName(forSourceURL sourceURL: String, rootDirectoryPath: String) -> String? {
        guard let relativePath = relativePath(forSourceURL: sourceURL, rootDirectoryPath: rootDirectoryPath) else {
            return nil
        }
        return relativePath.split(separator: "/").last.map(String.init)
    }

    static func relativePath(forSourceURL sourceURL: String, rootDirectoryPath: String) -> String? {
        guard let url = URL(string: sourceURL), url.isFileURL else { return nil }
        let root = URL(filePath: rootDirectoryPath, directoryHint: .isDirectory).standardizedFileURL
        let source = url.standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard source.path.hasPrefix(rootPath) else { return nil }
        return ModuleOutputFolder.normalized(String(source.path.dropFirst(rootPath.count)))
    }
}
