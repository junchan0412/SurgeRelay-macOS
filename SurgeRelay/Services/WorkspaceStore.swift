import Foundation

struct WorkspaceStore: Sendable {
    typealias Writer = @Sendable (Data, URL) throws -> Void
    let registryURL: URL
    private let writeData: Writer

    init(registryURL: URL = WorkspaceStore.defaultRegistryURL, writeData: @escaping Writer = { data, url in
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }) {
        self.registryURL = registryURL
        self.writeData = writeData
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
        settings.publishToLocal = false
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
}
