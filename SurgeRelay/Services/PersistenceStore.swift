import Foundation

enum PersistenceStore {
    private static let directoryLock = NSLock()
    nonisolated(unsafe) private static var qaConfigurationDirectory: URL?
    private static let configurationDirectoryKey = "SurgeRelay.configurationDirectory.v1"
    private static let legacySettingsKey = "SurgeRelay.settings.v1"
    private static let legacyUpstreamKey = "SurgeRelay.upstream.v1"
    private static let configurationFileNames = [
        "modules.json",
        "settings.json",
        "script-hub-state.json",
        "update-history.json",
        "selected-publish.json",
        "preview-drafts.json",
        "module-templates.json",
        "credentials.encrypted",
        "credentials.key"
    ]
    private static let configurationDirectoryNames = [
        "Backups",
        "Overrides",
        "ModuleVersions",
        "RestoreTransactions",
        "PublishedResourceTransactions",
        "PublishedResourceOwnership"
    ]

    static var configurationDirectoryURL: URL {
        if AppRuntimeOptions.isUIQAMode {
            return directoryLock.withLock { qaConfigurationDirectory }
                ?? AppRuntimeOptions.uiQADirectory.appending(path: "Configuration", directoryHint: .isDirectory)
        }
        let path = UserDefaults.standard.string(forKey: configurationDirectoryKey)
            ?? AppSettings.defaultConfigurationDirectory
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    static func selectConfigurationDirectory(_ directory: URL) {
        if AppRuntimeOptions.isUIQAMode {
            directoryLock.withLock { qaConfigurationDirectory = directory }
        } else {
            UserDefaults.standard.set(directory.path, forKey: configurationDirectoryKey)
        }
    }

    static var cacheDirectoryURL: URL {
        let directory = AppRuntimeOptions.isUIQAMode
            ? AppRuntimeOptions.uiQADirectory.appending(path: "Cache", directoryHint: .isDirectory)
            : FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/Surge Relay/Cache", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var registryURL: URL {
        configurationDirectoryURL.appending(path: "modules.json")
    }

    static var settingsURL: URL {
        configurationDirectoryURL.appending(path: "settings.json")
    }

    static var upstreamStateURL: URL {
        configurationDirectoryURL.appending(path: "script-hub-state.json")
    }

    static var updateHistoryURL: URL {
        configurationDirectoryURL.appending(path: "update-history.json")
    }

    static func loadModules(in directory: URL? = nil, allowLegacyFallback: Bool = true) -> [RelayModule] {
        let registryURL = (directory ?? configurationDirectoryURL).appending(path: "modules.json")
        if let modules: [RelayModule] = decodeFile(at: registryURL) {
            return modules
        }
        guard allowLegacyFallback, !AppRuntimeOptions.isUIQAMode else { return [] }
        let legacyURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Surge Relay/modules.json")
        guard let modules: [RelayModule] = decodeFile(at: legacyURL) else { return [] }
        try? write(modules, to: registryURL)
        return modules
    }

    static func saveModules(_ modules: [RelayModule]) throws {
        try write(modules, to: registryURL)
    }

    static func loadSettings(in directory: URL? = nil, allowLegacyFallback: Bool = true) -> AppSettings {
        let settingsURL = (directory ?? configurationDirectoryURL).appending(path: "settings.json")
        if let settings: AppSettings = decodeFile(at: settingsURL) {
            return settings
        }
        guard allowLegacyFallback, !AppRuntimeOptions.isUIQAMode else { return AppSettings() }
        if let data = UserDefaults.standard.data(forKey: legacySettingsKey),
           let settings = try? decoder.decode(AppSettings.self, from: data) {
            try? write(settings, to: settingsURL)
            return settings
        }
        let settings = AppSettings()
        try? write(settings, to: settingsURL)
        return settings
    }

    static func saveSettings(_ settings: AppSettings) {
        try? write(settings, to: settingsURL)
    }

    static func loadUpstreamState(in directory: URL? = nil, allowLegacyFallback: Bool = true) -> ScriptHubUpstreamState {
        let upstreamStateURL = (directory ?? configurationDirectoryURL).appending(path: "script-hub-state.json")
        if let state: ScriptHubUpstreamState = decodeFile(at: upstreamStateURL) {
            return state
        }
        guard allowLegacyFallback, !AppRuntimeOptions.isUIQAMode else { return ScriptHubUpstreamState() }
        if let data = UserDefaults.standard.data(forKey: legacyUpstreamKey),
           let state = try? decoder.decode(ScriptHubUpstreamState.self, from: data) {
            try? write(state, to: upstreamStateURL)
            return state
        }
        return ScriptHubUpstreamState()
    }

    static func saveUpstreamState(_ state: ScriptHubUpstreamState) {
        try? write(state, to: upstreamStateURL)
    }

    static var previewDraftsURL: URL {
        configurationDirectoryURL.appending(path: "preview-drafts.json")
    }

    static func loadPreviewDrafts(in directory: URL? = nil) -> [UUID: ModulePreviewDraft] {
        decodeFile(at: (directory ?? configurationDirectoryURL).appending(path: "preview-drafts.json")) ?? [:]
    }

    static func loadModuleTemplates(in directory: URL? = nil) -> [ModuleTemplate] {
        decodeFile(at: (directory ?? configurationDirectoryURL).appending(path: "module-templates.json")) ?? []
    }

    static func loadSelectedPublishAttempt(in directory: URL? = nil) -> SelectedPublishAttempt? {
        let value: SelectedPublishAttempt? = decodeFile(
            at: (directory ?? configurationDirectoryURL).appending(path: "selected-publish.json")
        )
        return value?.restored
    }

    static func saveSelectedPublishAttempt(_ attempt: SelectedPublishAttempt) throws {
        try write(attempt, to: configurationDirectoryURL.appending(path: "selected-publish.json"))
    }

    static func loadUpdateHistory(in directory: URL? = nil) -> [UpdateHistoryEntry] {
        decodeFile(at: (directory ?? configurationDirectoryURL).appending(path: "update-history.json")) ?? []
    }

    static func saveUpdateHistory(_ entries: [UpdateHistoryEntry]) {
        try? write(Array(entries.prefix(200)), to: updateHistoryURL)
    }

    static func useConfigurationDirectory(_ path: String) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        let sourceDirectory = configurationDirectoryURL
        let directory = URL(filePath: trimmed, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try migrateConfigurationFiles(from: sourceDirectory, to: directory)
        selectConfigurationDirectory(directory)
        try removeMigratedConfigurationFiles(from: sourceDirectory, to: directory)
    }

    static func migrateConfigurationFiles(from sourceDirectory: URL, to destinationDirectory: URL) throws {
        let sourceDirectory = sourceDirectory.standardizedFileURL
        let destinationDirectory = destinationDirectory.standardizedFileURL
        guard sourceDirectory != destinationDirectory else { return }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        for fileName in configurationFileNames {
            try copyConfigurationFileIfNeeded(
                named: fileName,
                from: sourceDirectory,
                to: destinationDirectory
            )
        }
        for directoryName in configurationDirectoryNames {
            try copyConfigurationDirectoryIfNeeded(
                named: directoryName,
                from: sourceDirectory,
                to: destinationDirectory
            )
        }
    }

    static func removeMigratedConfigurationFiles(from sourceDirectory: URL, to destinationDirectory: URL) throws {
        let sourceDirectory = sourceDirectory.standardizedFileURL
        let destinationDirectory = destinationDirectory.standardizedFileURL
        guard sourceDirectory != destinationDirectory else { return }

        let fileManager = FileManager.default
        for fileName in configurationFileNames {
            let sourceURL = sourceDirectory.appending(path: fileName)
            let destinationURL = destinationDirectory.appending(path: fileName)
            guard sourceURL.standardizedFileURL != destinationURL.standardizedFileURL,
                  fileManager.fileExists(atPath: sourceURL.path) else {
                continue
            }
            try fileManager.removeItem(at: sourceURL)
        }

        for directoryName in configurationDirectoryNames {
            let sourceURL = sourceDirectory.appending(path: directoryName, directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: sourceURL.path),
                  !destinationDirectory.isDescendant(of: sourceURL) else {
                continue
            }
            try fileManager.removeItem(at: sourceURL)
        }
    }

    private static func copyConfigurationFileIfNeeded(
        named fileName: String,
        from sourceDirectory: URL,
        to destinationDirectory: URL
    ) throws {
        let fileManager = FileManager.default
        let sourceURL = sourceDirectory.appending(path: fileName)
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }

        let destinationURL = destinationDirectory.appending(path: fileName)
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sourceData = try Data(contentsOf: sourceURL)
        if let destinationData = try? Data(contentsOf: destinationURL) {
            guard destinationData != sourceData else { return }
            try backupExistingDestinationFile(destinationURL, data: destinationData, root: destinationDirectory)
        }
        try sourceData.write(to: destinationURL, options: .atomic)
        if fileName == "credentials.encrypted" || fileName == "credentials.key" {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
        }
    }

    private static func copyConfigurationDirectoryIfNeeded(
        named directoryName: String,
        from sourceDirectory: URL,
        to destinationDirectory: URL
    ) throws {
        let sourceDirectory = sourceDirectory.standardizedFileURL
        let destinationDirectory = destinationDirectory.standardizedFileURL
        guard sourceDirectory != destinationDirectory else { return }

        let fileManager = FileManager.default
        let sourceRoot = sourceDirectory.appending(path: directoryName, directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: sourceRoot.path) else { return }

        let destinationRoot = destinationDirectory.appending(path: directoryName, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        for relativePath in try fileManager.subpathsOfDirectory(atPath: sourceRoot.path) {
            let sourceURL = sourceRoot.appending(path: relativePath)
            let destinationURL = destinationRoot.appending(path: relativePath)
            let isDirectory = try sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            if isDirectory {
                try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let sourceData = try Data(contentsOf: sourceURL)
                if let destinationData = try? Data(contentsOf: destinationURL),
                   destinationData != sourceData {
                    try backupExistingDestinationFile(destinationURL, data: destinationData, root: destinationDirectory)
                }
                try sourceData.write(to: destinationURL, options: .atomic)
            }
        }
    }

    private static func backupExistingDestinationFile(_ url: URL, data: Data, root: URL) throws {
        let relativePath = url.standardizedFileURL.path
            .replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
            .replacingOccurrences(of: "/", with: "__")
        let directory = root
            .appending(path: "Backups", directoryHint: .isDirectory)
            .appending(path: "configuration-migration", directoryHint: .isDirectory)
            .appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let destination = directory.appending(path: "\(stamp)-\(UUID().uuidString.prefix(6)).backup")
        try data.write(to: destination, options: .atomic)
    }

    private static func decodeFile<Value: Decodable>(at url: URL) -> Value? {
        if let data = try? Data(contentsOf: url),
           let value = try? decoder.decode(Value.self, from: data) {
            return value
        }
        for backup in backupFiles(for: url, configurationDirectory: url.deletingLastPathComponent()) {
            guard let data = try? Data(contentsOf: backup),
                  let value = try? decoder.decode(Value.self, from: data) else { continue }
            preserveCorruptFile(at: url)
            try? data.write(to: url, options: .atomic)
            return value
        }
        return nil
    }

    private static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try writeProtectedData(encoder.encode(value), to: url, configurationDirectory: url.deletingLastPathComponent())
    }

    static func writeProtectedData(_ data: Data, to url: URL, configurationDirectory: URL? = nil) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing = try? Data(contentsOf: url) {
            guard existing != data else { return }
            try createBackup(of: url, data: existing, configurationDirectory: configurationDirectory)
        }
        try data.write(to: url, options: .atomic)
    }

    private static func createBackup(of url: URL, data: Data, configurationDirectory: URL?) throws {
        let directory = (configurationDirectory ?? configurationDirectoryURL)
            .appending(path: "Backups", directoryHint: .isDirectory)
            .appending(path: url.lastPathComponent, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let destination = directory.appending(path: "\(stamp)-\(UUID().uuidString.prefix(6)).backup")
        try data.write(to: destination, options: .atomic)
        let files = backupFiles(for: url, configurationDirectory: configurationDirectory)
        for expired in files.dropFirst(20) {
            try? FileManager.default.removeItem(at: expired)
        }
    }

    private static func backupFiles(for url: URL, configurationDirectory: URL? = nil) -> [URL] {
        let directory = (configurationDirectory ?? configurationDirectoryURL)
            .appending(path: "Backups", directoryHint: .isDirectory)
            .appending(path: url.lastPathComponent, directoryHint: .isDirectory)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.sorted {
            let left = (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            return left > right
        }
    }

    private static func preserveCorruptFile(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let destination = url.deletingLastPathComponent()
            .appending(path: "\(url.lastPathComponent).corrupt-\(Int(Date.now.timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: destination)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension URL {
    func isDescendant(of ancestor: URL) -> Bool {
        let ancestorPath = ancestor.standardizedFileURL.path.hasSuffix("/")
            ? ancestor.standardizedFileURL.path
            : ancestor.standardizedFileURL.path + "/"
        let path = standardizedFileURL.path.hasSuffix("/")
            ? standardizedFileURL.path
            : standardizedFileURL.path + "/"
        return path.hasPrefix(ancestorPath)
    }
}

actor PreviewDraftWriter {
    private var latestRevision: UInt64 = 0

    func save(_ drafts: [UUID: ModulePreviewDraft], to url: URL, revision: UInt64) throws {
        guard revision >= latestRevision else { return }
        let data = try JSONEncoder().encode(drafts)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        latestRevision = revision
    }
}

final class ConfigurationPersistenceWriter: @unchecked Sendable {
    typealias WriteData = @Sendable (Data, URL) throws -> Void
    private let queue = DispatchQueue(label: "com.allenmiao.SurgeRelay.configuration-writer", qos: .utility)
    private let writeData: WriteData
    private var directory: URL
    private var failures: [String: String] = [:]
    private var retries: [String: @Sendable () throws -> Void] = [:]

    init(directory: URL, writeData: @escaping WriteData = { data, url in
        try PersistenceStore.writeProtectedData(data, to: url, configurationDirectory: url.deletingLastPathComponent())
    }) {
        self.directory = directory
        self.writeData = writeData
    }

    func enqueue<Value: Encodable & Sendable>(_ value: Value, fileName: String) {
        queue.async { [self] in
            let operation: @Sendable () throws -> Void = { [weak self] in
                guard let self else { return }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try self.writeData(encoder.encode(value), self.directory.appending(path: fileName))
            }
            execute(operation, fileName: fileName)
        }
    }

    func flush() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { try retryFailedWrites(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func migrate(to destination: URL, commit: @escaping @Sendable (URL) throws -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try retryFailedWrites()
                    let source = directory
                    try PersistenceStore.migrateConfigurationFiles(from: source, to: destination)
                    try commit(destination)
                    directory = destination
                    try PersistenceStore.removeMigratedConfigurationFiles(from: source, to: destination)
                    continuation.resume(returning: destination)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func currentDirectory() async -> URL {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: directory) }
        }
    }

    private func execute(_ operation: @escaping @Sendable () throws -> Void, fileName: String) {
        do {
            try operation()
            failures.removeValue(forKey: fileName)
            retries.removeValue(forKey: fileName)
        } catch {
            failures[fileName] = error.localizedDescription
            retries[fileName] = operation
        }
    }

    private func retryFailedWrites() throws {
        for (fileName, operation) in retries { execute(operation, fileName: fileName) }
        guard failures.isEmpty else {
            let message = failures.keys.sorted().map { "\($0)：\(failures[$0]!)" }.joined(separator: "；")
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
