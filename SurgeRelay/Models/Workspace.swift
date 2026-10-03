import Foundation

struct WorkspaceContext: Hashable, Sendable {
    var id: UUID
    var name: String
    var configurationDirectory: URL
    var cacheDirectory: URL
    var allowsLegacyFallback: Bool

    static let legacyID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    static var legacyDefault: Self {
        Self(id: legacyID, name: "默认工作区",
             configurationDirectory: PersistenceStore.configurationDirectoryURL,
             cacheDirectory: PersistenceStore.cacheDirectoryURL, allowsLegacyFallback: !AppRuntimeOptions.isUIQAMode)
    }
}

struct WorkspaceDescriptor: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var configurationDirectory: URL
    var cacheDirectory: URL
    var isLegacyDefault: Bool

    init(context: WorkspaceContext) {
        id = context.id
        name = context.name
        configurationDirectory = context.configurationDirectory
        cacheDirectory = context.cacheDirectory
        isLegacyDefault = context.id == WorkspaceContext.legacyID
    }

    var context: WorkspaceContext {
        WorkspaceContext(id: id, name: name, configurationDirectory: configurationDirectory,
                         cacheDirectory: cacheDirectory, allowsLegacyFallback: isLegacyDefault && !AppRuntimeOptions.isUIQAMode)
    }
}

struct WorkspaceRegistry: Codable, Equatable, Sendable {
    var activeID: UUID
    var workspaces: [WorkspaceDescriptor]
}
