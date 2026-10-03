import Foundation

enum ConfigurationManager {
    static var configurationDirectoryPath: String {
        PersistenceStore.configurationDirectoryURL.path
    }

    static func migrateConfiguration(to path: String, writer: ConfigurationPersistenceWriter,
                                     commit: @escaping @Sendable (URL) throws -> Void = PersistenceStore.selectConfigurationDirectory) async throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        let destination = URL(filePath: trimmed, directoryHint: .isDirectory).standardizedFileURL
        return try await writer.migrate(to: destination, commit: commit)
    }
}
