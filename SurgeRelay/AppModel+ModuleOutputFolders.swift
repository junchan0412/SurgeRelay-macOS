import Foundation

@MainActor
extension AppModel {
    func moduleOutputFolderOptions(
        storageLocation: ModuleStorageLocation? = nil,
        preserving selected: String? = nil
    ) -> [String] {
        ModuleOutputFolderCatalog.options(
            settings: settings,
            modules: modules,
            localFolders: localModuleOutputFolders,
            githubFolders: githubModuleOutputFolders,
            storageLocation: storageLocation,
            preserving: selected
        )
    }

    @discardableResult
    func createModuleOutputFolder(
        named rawValue: String,
        storageLocation: ModuleStorageLocation
    ) throws -> String {
        let plan = try ModuleOutputFolderCatalog.createPlan(
            named: rawValue,
            storageLocation: storageLocation,
            settings: settings,
            githubModuleOutputFolders: githubModuleOutputFolders,
            excludedLocalDirectories: [configurationStorageDirectory, cacheDirectoryURL]
        )
        if let localDirectoryURL = plan.localDirectoryURL {
            try FileManager.default.createDirectory(at: localDirectoryURL, withIntermediateDirectories: true)
            localModuleOutputFolders = ModuleOutputFolder.options(
                from: localModuleOutputFolders + [plan.folder]
            )
        }
        settings.customModuleOutputFolders = plan.customModuleOutputFolders
        githubModuleOutputFolders = plan.githubModuleOutputFolders
        saveSettings()
        statusMessage = plan.statusMessage
        return plan.folder
    }

    func refreshModuleOutputFolders(force: Bool = false, preserving selected: String? = nil) async {
        await refreshLocalModuleOutputFolders(force: force, preserving: selected)
        guard !Task.isCancelled else { return }
        let now = Date.now
        switch ModuleOutputFolderCatalog.refreshDecision(
            settings: settings,
            cachedConfiguration: githubModuleOutputFoldersConfiguration,
            lastRefreshedAt: githubModuleOutputFoldersLastRefreshedAt,
            now: now,
            force: force
        ) {
        case .reset(let state):
            applyModuleOutputFolderRefreshState(state)
            return
        case .reuseCached:
            return
        case .fetchRemote:
            break
        }

        do {
            let token = githubTokenStorageStatus == .notChecked ? "" : githubToken
            let folders = try await githubClient.listDirectories(settings: settings.github, token: token)
            applyModuleOutputFolderRefreshState(ModuleOutputFolderCatalog.successfulRefreshState(
                remoteFolders: folders,
                modules: modules,
                settings: settings.github,
                refreshedAt: now
            ))
        } catch {
            applyModuleOutputFolderRefreshState(ModuleOutputFolderCatalog.failedRefreshState(
                modules: modules,
                settings: settings.github,
                refreshedAt: now
            ))
        }
    }

    private func refreshLocalModuleOutputFolders(force: Bool, preserving selected: String?) async {
        let rootPath = settings.localModuleDirectory
        let now = Date.now
        guard ModuleOutputFolderCatalog.shouldRefreshLocalFolders(
            rootPath: rootPath,
            cachedRootPath: localModuleOutputFoldersRootPath,
            lastRefreshedAt: localModuleOutputFoldersLastRefreshedAt,
            folders: localModuleOutputFolders,
            preserving: selected,
            now: now,
            force: force
        ) else { return }
        let excludedDirectories = [configurationStorageDirectory, cacheDirectoryURL]
        let candidateFolders = settings.customModuleOutputFolders
            + modules.map(\.outputFolder)
            + moduleTemplates.map(\.outputFolder)
            + [selected].compactMap { $0 }
        let folders = await Task.detached(priority: .utility) {
            (try? LocalModuleFolderScanner.folders(
                in: rootPath,
                excluding: excludedDirectories,
                including: candidateFolders
            )) ?? []
        }.value
        guard !Task.isCancelled,
              settings.localModuleDirectory == rootPath,
              [configurationStorageDirectory, cacheDirectoryURL] == excludedDirectories else { return }
        localModuleOutputFolders = ModuleOutputFolder.options(from: folders)
        localModuleOutputFoldersRootPath = rootPath
        localModuleOutputFoldersLastRefreshedAt = now
    }

    private func applyModuleOutputFolderRefreshState(_ state: ModuleOutputFolderRefreshState) {
        githubModuleOutputFolders = state.githubModuleOutputFolders
        githubModuleOutputFoldersLastRefreshedAt = state.lastRefreshedAt
        githubModuleOutputFoldersConfiguration = state.configuration
    }
}
