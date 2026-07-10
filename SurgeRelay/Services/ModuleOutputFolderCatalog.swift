import Foundation

struct ModuleOutputFolderCreatePlan: Equatable, Sendable {
    var folder: String
    var localDirectoryURL: URL?
    var customModuleOutputFolders: [String]
    var githubModuleOutputFolders: [String]
    var statusMessage: String
}

struct ModuleOutputFolderRefreshState: Equatable, Sendable {
    var githubModuleOutputFolders: [String]
    var lastRefreshedAt: Date?
    var configuration: GitHubSettings?
}

enum ModuleOutputFolderRefreshDecision: Equatable, Sendable {
    case reset(ModuleOutputFolderRefreshState)
    case reuseCached
    case fetchRemote
}

enum ModuleOutputFolderCatalog {
    static let cacheInterval: TimeInterval = 300

    static func options(
        settings: AppSettings,
        modules: [RelayModule],
        localFolders: [String],
        githubFolders: [String],
        storageLocation: ModuleStorageLocation? = nil,
        preserving selected: String? = nil
    ) -> [String] {
        var configuredFolders: [String] = []
        if settings.publishToLocal, storageLocation == nil || storageLocation == .local {
            configuredFolders.append(contentsOf: localFolders)
        }
        if settings.publishToGitHub, storageLocation == nil || storageLocation == .gitHub {
            configuredFolders.append(contentsOf: githubFolders)
        }
        let moduleFolders = modules.compactMap { module in
            storageLocation == nil || module.storageLocation == storageLocation
                ? module.outputFolder
                : nil
        }
        return ModuleOutputFolder.options(
            from: configuredFolders + settings.customModuleOutputFolders + moduleFolders,
            preserving: selected
        )
    }

    static func createPlan(
        named rawValue: String,
        storageLocation: ModuleStorageLocation,
        settings: AppSettings,
        githubModuleOutputFolders: [String]
    ) throws -> ModuleOutputFolderCreatePlan {
        let folder = ModuleOutputFolder.normalized(rawValue)
        guard !folder.isEmpty else {
            throw RelayError.invalidOutput("请输入文件夹名称。")
        }

        let localDirectoryURL: URL?
        if storageLocation == .local {
            let rootPath = settings.localModuleDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rootPath.isEmpty else {
                throw RelayError.invalidOutput("请先设置本地模块根目录。")
            }
            var destination = URL(filePath: rootPath, directoryHint: .isDirectory).standardizedFileURL
            for component in ModuleOutputFolder.components(folder) {
                destination = destination.appending(path: component, directoryHint: .isDirectory)
            }
            localDirectoryURL = destination
        } else {
            localDirectoryURL = nil
        }

        var customFolders = Set(settings.customModuleOutputFolders.map(ModuleOutputFolder.normalized))
        customFolders.insert(folder)
        let nextCustomFolders = ModuleOutputFolder.options(from: Array(customFolders))
            .filter { !$0.isEmpty }
        let nextGitHubFolders = storageLocation == .gitHub
            ? ModuleOutputFolder.options(from: githubModuleOutputFolders + [folder])
            : ModuleOutputFolder.options(from: githubModuleOutputFolders)
        let statusMessage = storageLocation == .local
            ? "已在本地模块根目录创建文件夹 \(folder)"
            : "已记录 GitHub 文件夹 \(folder)，发布时会自动创建路径"
        return ModuleOutputFolderCreatePlan(
            folder: folder,
            localDirectoryURL: localDirectoryURL,
            customModuleOutputFolders: nextCustomFolders,
            githubModuleOutputFolders: nextGitHubFolders,
            statusMessage: statusMessage
        )
    }

    static func refreshDecision(
        settings: AppSettings,
        cachedConfiguration: GitHubSettings?,
        lastRefreshedAt: Date?,
        now: Date,
        force: Bool
    ) -> ModuleOutputFolderRefreshDecision {
        guard settings.publishToGitHub, settings.github.isConfigured else {
            return .reset(ModuleOutputFolderRefreshState(
                githubModuleOutputFolders: [ModuleOutputFolder.root],
                lastRefreshedAt: nil,
                configuration: nil
            ))
        }
        if !force,
           cachedConfiguration == settings.github,
           let lastRefreshedAt,
           now.timeIntervalSince(lastRefreshedAt) < cacheInterval {
            return .reuseCached
        }
        return .fetchRemote
    }

    static func successfulRefreshState(
        remoteFolders: [String],
        modules: [RelayModule],
        settings: GitHubSettings,
        refreshedAt: Date
    ) -> ModuleOutputFolderRefreshState {
        ModuleOutputFolderRefreshState(
            githubModuleOutputFolders: ModuleOutputFolder.options(from: remoteFolders + modules.map(\.outputFolder)),
            lastRefreshedAt: refreshedAt,
            configuration: settings
        )
    }

    static func failedRefreshState(
        modules: [RelayModule],
        settings: GitHubSettings,
        refreshedAt: Date
    ) -> ModuleOutputFolderRefreshState {
        ModuleOutputFolderRefreshState(
            githubModuleOutputFolders: ModuleOutputFolder.options(from: modules.map(\.outputFolder)),
            lastRefreshedAt: refreshedAt,
            configuration: settings
        )
    }
}
