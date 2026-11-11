import Foundation

@MainActor
extension AppModel {
    func moduleOutputFolderOptions(
        storageLocation: ModuleStorageLocation? = nil,
        preserving selected: String? = nil,
        outputFormat: ModuleOutputFormat = .surge
    ) -> [String] {
        ModuleOutputFolderCatalog.options(
            settings: settings,
            modules: modules,
            localFolders: localModuleOutputFoldersByClient[outputFormat] ?? (outputFormat == .surge ? localModuleOutputFolders : [ModuleOutputFolder.root]),
            githubFolders: githubModuleOutputFolders,
            storageLocation: storageLocation,
            preserving: selected,
            outputFormat: outputFormat
        )
    }

    @discardableResult
    func createModuleOutputFolder(
        named rawValue: String,
        storageLocation: ModuleStorageLocation,
        outputFormat: ModuleOutputFormat = .surge
    ) throws -> String {
        let plan = try ModuleOutputFolderCatalog.createPlan(
            named: rawValue,
            storageLocation: storageLocation,
            settings: settings,
            githubModuleOutputFolders: githubModuleOutputFolders,
            excludedLocalDirectories: [configurationStorageDirectory, cacheDirectoryURL],
            outputFormat: outputFormat
        )
        if let localDirectoryURL = plan.localDirectoryURL {
            try FileManager.default.createDirectory(at: localDirectoryURL, withIntermediateDirectories: true)
            let folders = ModuleOutputFolder.options(from: (localModuleOutputFoldersByClient[outputFormat] ?? []) + [plan.folder])
            localModuleOutputFoldersByClient[outputFormat] = folders
            if outputFormat == .surge { localModuleOutputFolders = folders }
        }
        settings.customModuleOutputFolders = plan.customModuleOutputFolders
        githubModuleOutputFolders = plan.githubModuleOutputFolders
        saveSettings()
        statusMessage = plan.statusMessage
        return plan.folder
    }

    func refreshModuleOutputFolders(force: Bool = false, preserving selected: String? = nil, outputFormat: ModuleOutputFormat? = nil) async {
        if let outputFormat {
            await refreshLocalModuleOutputFolders(force: force, preserving: selected, outputFormat: outputFormat)
        } else {
            for format in ModuleOutputFormat.allCases where settings.isLocalPublishingEnabled(for: format) {
                await refreshLocalModuleOutputFolders(force: force, preserving: selected, outputFormat: format)
            }
        }
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

    private func refreshLocalModuleOutputFolders(force: Bool, preserving selected: String?, outputFormat: ModuleOutputFormat) async {
        let rootPath = settings.localModuleDirectory(for: outputFormat)
        let now = Date.now
        guard ModuleOutputFolderCatalog.shouldRefreshLocalFolders(
            rootPath: rootPath,
            cachedRootPath: localModuleOutputFoldersRootPaths[outputFormat] ?? (outputFormat == .surge ? localModuleOutputFoldersRootPath : nil),
            lastRefreshedAt: localModuleOutputFoldersLastRefreshes[outputFormat] ?? (outputFormat == .surge ? localModuleOutputFoldersLastRefreshedAt : nil),
            folders: localModuleOutputFoldersByClient[outputFormat] ?? (outputFormat == .surge ? localModuleOutputFolders : []),
            preserving: selected,
            now: now,
            force: force
        ) else { return }
        let excludedDirectories = [configurationStorageDirectory, cacheDirectoryURL]
        let candidateFolders = settings.customModuleOutputFolders
            + modules.filter { $0.outputFormat == outputFormat }.map(\.outputFolder)
            + moduleTemplates.filter { $0.outputFormat == outputFormat }.map(\.outputFolder)
            + [selected].compactMap { $0 }
        let folders = await Task.detached(priority: .utility) {
            (try? LocalModuleFolderScanner.folders(
                in: rootPath,
                excluding: excludedDirectories,
                including: candidateFolders
            )) ?? []
        }.value
        guard !Task.isCancelled,
              settings.localModuleDirectory(for: outputFormat) == rootPath,
              [configurationStorageDirectory, cacheDirectoryURL] == excludedDirectories else { return }
        localModuleOutputFoldersByClient[outputFormat] = ModuleOutputFolder.options(from: folders)
        localModuleOutputFoldersRootPaths[outputFormat] = rootPath
        localModuleOutputFoldersLastRefreshes[outputFormat] = now
        if outputFormat == .surge {
            localModuleOutputFolders = ModuleOutputFolder.options(from: folders)
            localModuleOutputFoldersRootPath = rootPath
            localModuleOutputFoldersLastRefreshedAt = now
        }
    }

    private func applyModuleOutputFolderRefreshState(_ state: ModuleOutputFolderRefreshState) {
        githubModuleOutputFolders = state.githubModuleOutputFolders
        githubModuleOutputFoldersLastRefreshedAt = state.lastRefreshedAt
        githubModuleOutputFoldersConfiguration = state.configuration
    }
}
