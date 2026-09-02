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
                shouldPublishStandalone(
                    $0,
                    destination: destination,
                    combinedModuleEnabled: combinedModuleEnabled
                )
            },
            combinedModuleIDs: Set(ModuleRefreshPlanner.combinedContributorModules(
                in: modules,
                combinedModuleEnabled: combinedModuleEnabled
            ).map(\.id))
        )
    }

    /// Whether a module's standalone file should be written for `destination`.
    ///
    /// A local module's own `.sgmodule` file is its only on-disk materialization
    /// when it is not carried by an enabled combined module, so it must be written
    /// even if `publishesStandalone` is off — otherwise updating a cache-only local
    /// module (e.g. with the combined module disabled) leaves its source file
    /// untouched on disk. Self-authored local sources are still protected from
    /// self-overwrite by `shouldSkipStandaloneLocalExport`.
    static func shouldPublishStandalone(
        _ module: RelayModule,
        destination: PublishDestination,
        combinedModuleEnabled: Bool
    ) -> Bool {
        let hasTarget = destination == .local
            ? module.hasLocalStorageTarget
            : module.hasGitHubStorageTarget
        guard hasTarget else { return false }
        if module.publishesStandalone { return true }
        return destination == .local
            && !ModuleRefreshPlanner.contributesToCombined(
                module,
                combinedModuleEnabled: combinedModuleEnabled
            )
    }

    static func selectedPlan(
        modules: [RelayModule],
        moduleIDs: Set<UUID>,
        combinedModuleEnabled: Bool,
        destination: PublishDestination
    ) -> PublishPlan {
        PublishPlan(
            standaloneModules: modules.filter {
                moduleIDs.contains($0.id) &&
                    shouldPublishStandalone(
                        $0,
                        destination: destination,
                        combinedModuleEnabled: combinedModuleEnabled
                    )
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
        // 只有“转换前来源”是本地文件、且该文件位于本地根目录之下的模块，
        // 才存在需要避免自覆盖的来源文件。远程来源本地模块的
        // localStorageRelativePath 只是发布输出路径，不是来源，不能当作来源。
        guard URL(string: module.sourceURL)?.isFileURL == true else { return nil }
        if module.hasLocalStorageTarget, let relativePath = module.localStorageRelativePath {
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
