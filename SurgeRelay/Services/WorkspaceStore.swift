import Foundation

struct WorkspaceStore: Sendable {
    typealias Writer = @Sendable (Data, URL) throws -> Void
    let registryURL: URL
    private let legacyComponentsDirectory: URL?
    private let writeData: Writer

    init(registryURL: URL = WorkspaceStore.defaultRegistryURL,
         legacyComponentsDirectory: URL? = WorkspaceStore.defaultLegacyComponentsDirectory,
         writeData: @escaping Writer = { data, url in
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }) {
        self.registryURL = registryURL
        self.legacyComponentsDirectory = legacyComponentsDirectory
        self.writeData = writeData
    }

    static var defaultLegacyComponentsDirectory: URL? {
        AppRuntimeOptions.isUIQAMode ? nil : FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Surge Relay/Components", directoryHint: .isDirectory)
    }

    static var defaultRegistryURL: URL {
        let root = AppRuntimeOptions.isUIQAMode
            ? AppRuntimeOptions.uiQADirectory
            : FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Surge Relay")
        return root.appending(path: "workspaces.json")
    }

    func load(defaultContext: WorkspaceContext) throws -> WorkspaceRegistry {
        guard FileManager.default.fileExists(atPath: registryURL.path) else {
            return WorkspaceRegistry(activeID: defaultContext.id, workspaces: [WorkspaceDescriptor(context: defaultContext)])
        }
        let registry = try JSONDecoder().decode(WorkspaceRegistry.self, from: Data(contentsOf: registryURL))
        guard Set(registry.workspaces.map(\.id)).count == registry.workspaces.count,
              registry.workspaces.contains(where: { $0.id == registry.activeID }) else {
            throw RelayError.invalidOutput("工作区登记文件无效，未更改任何工作区内容。")
        }
        return registry
    }

    func save(_ registry: WorkspaceRegistry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeData(encoder.encode(registry), registryURL)
    }

    func create(name: String, in registry: WorkspaceRegistry) throws -> WorkspaceRegistry {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RelayError.invalidOutput("请输入工作区名称。") }
        let id = UUID()
        let root = registryURL.deletingLastPathComponent().appending(path: "Workspaces/\(id.uuidString.lowercased())", directoryHint: .isDirectory)
        let context = WorkspaceContext(id: id, name: name, configurationDirectory: root.appending(path: "Configuration", directoryHint: .isDirectory),
                                       cacheDirectory: root.appending(path: "Cache", directoryHint: .isDirectory), allowsLegacyFallback: false)
        try FileManager.default.createDirectory(at: context.configurationDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: context.cacheDirectory, withIntermediateDirectories: true)
        var settings = AppSettings()
        settings.publishToLocal = true
        settings.publishToGitHub = false
        settings.automaticallyPublish = false
        settings.automaticallyUpdateOnLaunch = false
        settings.automaticallyUpdateScriptHub = false
        settings.webServerEnabled = false
        settings.githubToken = ""
        settings.github.owner = ""
        settings.github.repository = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try writeData(encoder.encode([RelayModule]()), context.configurationDirectory.appending(path: "modules.json"))
        try writeData(encoder.encode(settings), context.configurationDirectory.appending(path: "settings.json"))
        var next = registry
        next.workspaces.append(WorkspaceDescriptor(context: context))
        try save(next)
        return next
    }

    func validate(_ workspace: WorkspaceDescriptor) throws {
        guard workspace.configurationDirectory.isFileURL, workspace.cacheDirectory.isFileURL else {
            throw RelayError.invalidOutput("工作区目录必须是本地文件路径。")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let root = workspace.configurationDirectory
        for file in ["modules.json", "settings.json"] {
            let url = root.appending(path: file)
            if workspace.isLegacyDefault, !FileManager.default.fileExists(atPath: url.path) { continue }
            let data = try Data(contentsOf: url)
            if file == "modules.json" { _ = try decoder.decode([RelayModule].self, from: data) }
            else { _ = try decoder.decode(AppSettings.self, from: data) }
        }
    }

    func validateRelocation(id: UUID, to directory: URL, registry: WorkspaceRegistry) throws {
        let candidate = directory.resolvingSymlinksInPath().standardizedFileURL.path
        for workspace in registry.workspaces where workspace.id != id {
            for root in [workspace.configurationDirectory, workspace.cacheDirectory] {
                let path = root.resolvingSymlinksInPath().standardizedFileURL.path
                guard candidate != path, !candidate.hasPrefix(path + "/"), !path.hasPrefix(candidate + "/") else {
                    throw RelayError.invalidOutput("该目录属于另一个工作区。请使用“切换工作区”，不要将配置迁移到这里。")
                }
            }
        }
    }

    func relocate(id: UUID, to directory: URL, fallback: WorkspaceRegistry) throws {
        var registry = try load(defaultContext: fallback.workspaces[0].context)
        if !FileManager.default.fileExists(atPath: registryURL.path) { registry = fallback }
        guard let index = registry.workspaces.firstIndex(where: { $0.id == id }) else { throw RelayError.invalidOutput("工作区已不存在。") }
        registry.workspaces[index].configurationDirectory = directory
        try save(registry)
    }

    func migrateWorkspace(id: UUID, to destinationRoot: URL, registry: WorkspaceRegistry) throws -> WorkspaceRegistry {
        guard destinationRoot.isFileURL, let index = registry.workspaces.firstIndex(where: { $0.id == id }) else {
            throw RelayError.invalidOutput("请选择有效的工作区迁移目录。")
        }
        let root = destinationRoot.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let source = registry.workspaces[index]
        var destination = source
        destination.configurationDirectory = root.appending(path: "Configuration", directoryHint: .isDirectory)
        destination.cacheDirectory = root.appending(path: "Cache", directoryHint: .isDirectory)
        let sourceRoots = [source.configurationDirectory, source.cacheDirectory].map {
            $0.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        }
        let targetRoots = [destination.configurationDirectory, destination.cacheDirectory]
        if zip(sourceRoots, targetRoots).allSatisfy({ $0.0 == $0.1 }) { return registry }
        try validateRelocation(id: id, to: root, registry: registry)
        for target in targetRoots {
            for origin in sourceRoots where target != origin {
                guard !target.path.hasPrefix(origin.path + "/"), !origin.path.hasPrefix(target.path + "/") else {
                    throw RelayError.invalidOutput("迁移目录不能位于当前工作区的数据目录内，也不能包含当前数据目录。")
                }
            }
        }
        let manager = FileManager.default
        for (origin, target) in zip(sourceRoots, targetRoots) where origin != target && manager.fileExists(atPath: target.path) {
            let attributes = try manager.attributesOfItem(atPath: target.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  try manager.contentsOfDirectory(atPath: target.path).isEmpty else {
                throw RelayError.invalidOutput("目标 \(target.lastPathComponent) 已有内容，请选择空的工作区目录。")
            }
        }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appending(path: ".workspace-\(id.uuidString.lowercased())-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        var installed: [URL] = []
        var removedEmptyDirectories: [URL] = []
        do {
            try materializeLegacyComponents(for: source)
            for (offset, pair) in zip(sourceRoots, targetRoots).enumerated() where pair.0 != pair.1 {
                let staged = staging.appending(path: pair.1.lastPathComponent, directoryHint: .isDirectory)
                if offset == 0 {
                    try PersistenceStore.migrateConfigurationFiles(from: pair.0, to: staged)
                } else if manager.fileExists(atPath: pair.0.path) {
                    try manager.copyItem(at: pair.0, to: staged)
                } else {
                    try manager.createDirectory(at: staged, withIntermediateDirectories: true)
                }
            }
            for (origin, target) in zip(sourceRoots, targetRoots) where origin != target {
                if manager.fileExists(atPath: target.path) {
                    guard (try manager.attributesOfItem(atPath: target.path)[.type]) as? FileAttributeType == .typeDirectory,
                          try manager.contentsOfDirectory(atPath: target.path).isEmpty else {
                        throw RelayError.invalidOutput("目标 \(target.lastPathComponent) 在迁移期间新增了内容，已保留，请重新选择目录。")
                    }
                    try manager.removeItem(at: target)
                    removedEmptyDirectories.append(target)
                }
                try manager.moveItem(at: staging.appending(path: target.lastPathComponent), to: target)
                installed.append(target)
            }
            try validate(destination)
            var next = registry
            next.workspaces[index] = destination
            try save(next)
            return next
        } catch {
            for target in installed { try? manager.removeItem(at: target) }
            for target in removedEmptyDirectories { try? manager.createDirectory(at: target, withIntermediateDirectories: true) }
            throw error
        }
    }

    func removeMigratedWorkspaceData(from source: WorkspaceDescriptor, to destination: WorkspaceDescriptor,
                                     registry: WorkspaceRegistry) throws -> String? {
        let configuration = source.configurationDirectory.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let cache = source.cacheDirectory.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let targetConfiguration = destination.configurationDirectory.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let targetCache = destination.cacheDirectory.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        if configuration != targetConfiguration {
            try PersistenceStore.removeMigratedConfigurationFiles(from: configuration, to: targetConfiguration)
        }
        guard cache != targetCache else { return nil }
        let protected = [configuration, targetConfiguration, targetCache, registryURL] + registry.workspaces.filter { $0.id != source.id }
            .flatMap { [$0.configurationDirectory, $0.cacheDirectory] }
        guard !protected.contains(where: { item in
            let path = item.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
            return path == cache.path || path.hasPrefix(cache.path + "/")
        }) else { return "工作区已迁移；旧缓存内包含配置或工作区登记数据，已保留：\(cache.path)" }
        if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
        return nil
    }

    private func materializeLegacyComponents(for workspace: WorkspaceDescriptor) throws {
        guard workspace.isLegacyDefault, let legacyComponentsDirectory else { return }
        let modules = PersistenceStore.loadModules(in: workspace.configurationDirectory, allowLegacyFallback: false)
        let manager = FileManager.default
        for module in modules {
            let legacy = legacyComponentsDirectory.appending(path: "\(module.id.uuidString).sgmodule")
            guard manager.fileExists(atPath: legacy.path) else { continue }
            let snapshot = workspace.cacheDirectory.appending(path: "Snapshots/\(module.id.uuidString.lowercased())")
            let destination = manager.fileExists(atPath: snapshot.path) ? snapshot.appending(path: "Content.cache")
                : workspace.cacheDirectory.appending(path: "Components/\(module.id.uuidString).cache")
            guard !manager.fileExists(atPath: destination.path) else { continue }
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: legacy, to: destination)
        }
    }
}
