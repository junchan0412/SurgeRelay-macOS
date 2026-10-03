import Foundation
import Darwin

enum PublishedResourcePhase: String, CaseIterable, Sendable {
    case staged, journalPrepared, beforeRename, renamed, acknowledging, ownershipPersisted, journalRemoved, acknowledged
}

struct LocalPublishPartialFailure: LocalizedError {
    let underlyingError: any Error
    let writtenPaths: [String]
    var errorDescription: String? { underlyingError.localizedDescription }
}

actor ModuleFileStore {
    private let cacheRoot: URL?
    private var configurationRoot: URL?
    private let allowsLegacyFallback: Bool
    private let restoreInterruption: (@Sendable (ModuleRestorePhase) throws -> Void)?
    private let resourceInterruption: (@Sendable (PublishedResourcePhase) throws -> Void)?
    private var recoveringRestores: Set<UUID> = []

    init(cacheDirectory: URL? = nil, configurationDirectory: URL? = nil, allowsLegacyFallback: Bool? = nil,
         restoreInterruption: (@Sendable (ModuleRestorePhase) throws -> Void)? = nil,
         resourceInterruption: (@Sendable (PublishedResourcePhase) throws -> Void)? = nil) {
        cacheRoot = cacheDirectory
        configurationRoot = configurationDirectory
        self.allowsLegacyFallback = allowsLegacyFallback ?? (cacheDirectory == nil)
        self.restoreInterruption = restoreInterruption
        self.resourceInterruption = resourceInterruption
    }

    func relocateConfigurationDirectory(to directory: URL) { configurationRoot = directory }

    private var cacheDirectory: URL { cacheRoot ?? PersistenceStore.cacheDirectoryURL }
    private var storageConfigurationDirectory: URL { configurationRoot ?? cacheRoot ?? PersistenceStore.configurationDirectoryURL }
    private var snapshotDirectory: URL { cacheDirectory.appending(path: "Snapshots", directoryHint: .isDirectory) }
    private final class CoordinationOutcome<Value>: @unchecked Sendable {
        var result: Result<Value, Error>?
    }

    private var componentDirectory: URL {
        cacheDirectory.appending(path: "Components", directoryHint: .isDirectory)
    }

    private var overrideDirectory: URL {
        storageConfigurationDirectory.appending(path: "Overrides", directoryHint: .isDirectory)
    }

    private var assetDirectory: URL {
        cacheDirectory.appending(path: "Assets", directoryHint: .isDirectory)
    }

    private var combinedCacheURL: URL {
        cacheDirectory.appending(path: "Combined.cache")
    }

    private var combinedOverrideURL: URL {
        cacheDirectory.appending(path: "CombinedOverride.cache")
    }

    private var combinedRebuildMarkerURL: URL { cacheDirectory.appending(path: "CombinedNeedsRebuild") }

    func writeComponent(_ content: String, id: UUID) throws {
        try recoverInterruptedRestore(id: id)
        try FileManager.default.createDirectory(at: componentDirectory, withIntermediateDirectories: true)
        try Data(SurgeModuleSanitizer.sanitize(content).utf8).write(to: componentURL(for: id), options: .atomic)
    }

    func commitConversion(_ result: ConversionResult, id: UUID) throws {
        try recoverInterruptedRestore(id: id)
        try Task.checkCancellation()
        let manager = FileManager.default
        try manager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        let staging = snapshotDirectory.appending(path: ".\(id.uuidString)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        try Data(SurgeModuleSanitizer.sanitize(result.content).utf8).write(to: staging.appending(path: "Content.cache"))
        try stageAssets(result.assets, id: id, at: staging.appending(path: "Assets", directoryHint: .isDirectory))
        try Task.checkCancellation()
        _ = try recordCurrentVersion(id: id, reason: .beforeUpdate)
        let destination = snapshotURL(for: id)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
    }

    static let maximumVersionCount = 20
    static let maximumVersionBytes = 128 * 1024 * 1024

    private var versionHistoryDirectory: URL {
        storageConfigurationDirectory.appending(path: "ModuleVersions", directoryHint: .isDirectory)
    }

    func versionHistoryBarrier() {}

    func removeModuleVersions(id: UUID) throws {
        let root = versionHistoryDirectory.appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func currentVersionContent(id: UUID, reason: ModuleVersionReason = .current) throws -> ModuleVersionContent? {
        let current = try currentVersionState(id: id, reason: reason)
        if let problem = current.problem { throw RelayError.invalidOutput(problem) }
        return current.content
    }

    func currentVersionState(id: UUID, reason: ModuleVersionReason = .current) throws -> ModuleVersionCurrentState {
        try recoverInterruptedRestore(id: id)
        if allowsLegacyFallback, !AppRuntimeOptions.isUIQAMode, !FileManager.default.fileExists(atPath: componentURL(for: id).path) {
            _ = try? readConvertedComponent(id: id)
        }
        return try currentVersionState(from: captureRawRestoreState(id: id), id: id, reason: reason)
    }

    @discardableResult
    func recordCurrentVersion(id: UUID, reason: ModuleVersionReason) throws -> ModuleVersionRecord? {
        guard let version = try currentVersionContent(id: id, reason: reason) else { return nil }
        return try storeVersion(version)
    }

    func moduleVersions(id: UUID) throws -> [ModuleVersionRecord] {
        let root = versionHistoryDirectory.appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .compactMap { directory -> ModuleVersionRecord? in
                guard let versionID = UUID(uuidString: directory.lastPathComponent),
                      let data = try? Data(contentsOf: directory.appending(path: "Version.json")),
                      let record = try? JSONDecoder().decode(ModuleVersionRecord.self, from: data),
                      record.id == versionID, record.moduleID == id else { return nil }
                return record
            }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString > $1.id.uuidString : $0.createdAt > $1.createdAt }
    }

    func readModuleVersion(id: UUID, versionID: UUID) throws -> ModuleVersionContent {
        let root = versionURL(moduleID: id, versionID: versionID)
        let record = try JSONDecoder().decode(ModuleVersionRecord.self, from: Data(contentsOf: root.appending(path: "Version.json")))
        guard record.id == versionID, record.moduleID == id else { throw RelayError.invalidOutput("历史版本不属于此模块。") }
        let contentData = try Data(contentsOf: root.appending(path: "Content.module"))
        guard contentData.sha256String == record.contentHash, let content = String(data: contentData, encoding: .utf8) else {
            throw RelayError.invalidOutput("历史正文校验失败，未修改当前内容。")
        }
        var converted: String?
        if let expectedHash = record.convertedContentHash {
            let data = try Data(contentsOf: root.appending(path: "Converted.module"))
            guard data.sha256String == expectedHash, let text = String(data: data, encoding: .utf8) else {
                throw RelayError.invalidOutput("历史转换正文校验失败。")
            }
            converted = text
        }
        let prefix = "assets/\(id.uuidString.lowercased())/"
        guard Set(record.assets.map(\.path)).count == record.assets.count else {
            throw RelayError.invalidOutput("历史脚本清单包含重复路径。")
        }
        var assets: [GeneratedAsset] = []
        for asset in record.assets {
            guard asset.path.hasPrefix(prefix) else { throw RelayError.invalidOutput("历史脚本路径无效。") }
            let file = try exportURL(root: root.appending(path: "Assets", directoryHint: .isDirectory), relativePath: String(asset.path.dropFirst(prefix.count)))
            let data = try Data(contentsOf: file)
            guard data.sha256String == asset.contentHash, data.count == asset.byteCount else {
                throw RelayError.invalidOutput("历史脚本校验失败：\(asset.path)")
            }
            assets.append(GeneratedAsset(relativePath: asset.path, data: data))
        }
        let verified = try makeVersionContent(id: id, content: content, converted: converted, hasOverride: record.hasOverride, assets: assets, reason: record.reason)
        guard verified.record.fingerprint == record.fingerprint, verified.record.byteCount == record.byteCount else {
            throw RelayError.invalidOutput("历史版本清单校验失败。")
        }
        return ModuleVersionContent(record: record, content: content, convertedContent: converted, assets: assets)
    }

    func restoreModuleVersion(id: UUID, versionID: UUID, expectedFingerprint: String) throws -> ModuleVersionContent {
        try recoverInterruptedRestore(id: id)
        let version = try readModuleVersion(id: id, versionID: versionID)
        if allowsLegacyFallback, !AppRuntimeOptions.isUIQAMode, !FileManager.default.fileExists(atPath: componentURL(for: id).path) {
            _ = try? readConvertedComponent(id: id)
        }
        let previous = try captureRawRestoreState(id: id)
        let current = try currentVersionState(from: previous, id: id, reason: .beforeRestore)
        guard current.fingerprint == expectedFingerprint else {
            throw RelayError.invalidOutput("当前正文或脚本在比较后发生变化，请重新比较后回退。")
        }
        if let content = current.content { _ = try storeVersion(content) }
        try installVersionContent(version, previous: previous, preservesDamagedCurrent: current.problem != nil, id: id)
        return try makeVersionContent(id: id, content: version.content, converted: version.convertedContent ?? version.content,
                                      hasOverride: true, assets: version.assets, reason: .restored)
    }

    private struct VersionIdentity: Codable {
        var contentHash: String
        var convertedContentHash: String?
        var hasOverride: Bool
        var assets: [ModuleVersionAsset]
    }

    private func makeVersionContent(id: UUID, content: String, converted: String?, hasOverride: Bool, assets: [GeneratedAsset], reason: ModuleVersionReason) throws -> ModuleVersionContent {
        let contentHash = Data(content.utf8).sha256String
        let convertedHash = converted.map { Data($0.utf8).sha256String }
        let sorted = assets.sorted { $0.relativePath < $1.relativePath }
        let manifest = sorted.map { ModuleVersionAsset(path: $0.relativePath, contentHash: $0.data.sha256String, byteCount: $0.data.count) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let identity = VersionIdentity(contentHash: contentHash, convertedContentHash: convertedHash, hasOverride: hasOverride, assets: manifest)
        let record = ModuleVersionRecord(id: UUID(), moduleID: id, createdAt: .now, reason: reason, contentHash: contentHash,
                                         convertedContentHash: convertedHash, hasOverride: hasOverride, assets: manifest,
                                         fingerprint: try encoder.encode(identity).sha256String,
                                         byteCount: content.utf8.count + (converted?.utf8.count ?? 0) + sorted.reduce(0) { $0 + $1.data.count })
        return ModuleVersionContent(record: record, content: content, convertedContent: converted, assets: sorted)
    }

    private func versionURL(moduleID: UUID, versionID: UUID) -> URL {
        versionHistoryDirectory.appending(path: moduleID.uuidString.lowercased(), directoryHint: .isDirectory)
            .appending(path: versionID.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    private func storeVersion(_ version: ModuleVersionContent) throws -> ModuleVersionRecord {
        if let latest = try moduleVersions(id: version.record.moduleID).first, latest.fingerprint == version.record.fingerprint { return latest }
        let destination = versionURL(moduleID: version.record.moduleID, versionID: version.record.id)
        let root = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = root.appending(path: ".\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        try PersistenceStore.writeProtectedData(Data(version.content.utf8), to: staging.appending(path: "Content.module"), configurationDirectory: storageConfigurationDirectory)
        if let converted = version.convertedContent {
            try PersistenceStore.writeProtectedData(Data(converted.utf8), to: staging.appending(path: "Converted.module"), configurationDirectory: storageConfigurationDirectory)
        }
        try stageAssets(version.assets, id: version.record.moduleID, at: staging.appending(path: "Assets", directoryHint: .isDirectory))
        try PersistenceStore.writeProtectedData(JSONEncoder().encode(version.record), to: staging.appending(path: "Version.json"), configurationDirectory: storageConfigurationDirectory)
        try FileManager.default.moveItem(at: staging, to: destination)
        let records = try moduleVersions(id: version.record.moduleID)
        var retainedBytes = 0
        for (index, record) in records.enumerated() {
            if index > 0, index >= Self.maximumVersionCount || retainedBytes + record.byteCount > Self.maximumVersionBytes {
                try FileManager.default.removeItem(at: versionURL(moduleID: record.moduleID, versionID: record.id))
            } else {
                retainedBytes += record.byteCount
            }
        }
        return version.record
    }

    private struct RawRestoreState {
        var converted: Data?
        var override: Data?
        var assets: [GeneratedAsset]
    }

    private struct RawRestoreIdentity: Codable {
        var convertedHash: String?
        var overrideHash: String?
        var assets: [ModuleVersionAsset]
    }

    private struct RestoreJournal: Codable {
        enum Phase: String, Codable { case prepared, committed, finalized }
        var id: UUID
        var moduleID: UUID
        var phase: Phase
        var preservesDamagedCurrent: Bool
        var previousMetadataPending: RestoreMetadataPending? = nil
    }

    private struct RestoreMetadataPending: Codable {
        var moduleID: UUID
        var transactionID: UUID
    }

    private struct InjectedRestoreInterruption: Error {
        var underlying: any Error
    }

    private var restoreJournalDirectory: URL {
        storageConfigurationDirectory.appending(path: "RestoreTransactions", directoryHint: .isDirectory)
    }

    @discardableResult
    func recoverInterruptedVersionRestores() throws -> Bool {
        if FileManager.default.fileExists(atPath: restoreJournalDirectory.path) {
            for item in try FileManager.default.contentsOfDirectory(at: restoreJournalDirectory, includingPropertiesForKeys: nil) {
                if let id = UUID(uuidString: item.lastPathComponent) { try recoverInterruptedRestore(id: id) }
            }
        }
        let pending = try pendingRestoreMetadataIDs()
        return FileManager.default.fileExists(atPath: combinedRebuildMarkerURL.path) || !pending.isEmpty
    }

    func pendingVersionRestoreModuleIDs() throws -> Set<UUID> {
        _ = try recoverInterruptedVersionRestores()
        return try pendingRestoreMetadataIDs()
    }

    func acknowledgeVersionRestoreMetadata(ids: Set<UUID>) throws {
        guard !FileManager.default.fileExists(atPath: combinedRebuildMarkerURL.path) else {
            throw RelayError.invalidOutput("总模块缓存尚未重建，不能确认历史恢复已完成。")
        }
        for id in ids {
            let url = restoreMetadataURL(id: id)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    private func restoreMetadataURL(id: UUID) -> URL {
        restoreJournalDirectory.appending(path: "MetadataPending", directoryHint: .isDirectory)
            .appending(path: id.uuidString.lowercased() + ".json")
    }

    private func pendingRestoreMetadataIDs() throws -> Set<UUID> {
        let directory = restoreJournalDirectory.appending(path: "MetadataPending", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var ids: Set<UUID> = []
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            guard file.pathExtension == "json", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            let pending = try JSONDecoder().decode(RestoreMetadataPending.self, from: Data(contentsOf: file))
            guard pending.moduleID == id else { throw RelayError.invalidOutput("恢复元数据确认记录归属无效。") }
            ids.insert(id)
        }
        return ids
    }

    private func markRestoreMetadataPending(_ journal: RestoreJournal) throws {
        let url = restoreMetadataURL(id: journal.moduleID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeRestoreData(JSONEncoder().encode(RestoreMetadataPending(moduleID: journal.moduleID, transactionID: journal.id)), to: url)
    }

    private func markCombinedForRebuild() throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try writeRestoreData(Data("version-restore\n".utf8), to: combinedRebuildMarkerURL)
    }

    private func restoreCheckpoint(_ phase: ModuleRestorePhase) throws {
        do { try restoreInterruption?(phase) }
        catch { throw InjectedRestoreInterruption(underlying: error) }
    }

    private func captureRawRestoreState(id: UUID) throws -> RawRestoreState {
        let manager = FileManager.default
        let convertedURL = componentURL(for: id)
        let overrideURL = componentOverrideURL(for: id)
        let legacyOverride = cacheDirectory.appending(path: "Overrides/\(id.uuidString).cache")
        let effectiveOverride = manager.fileExists(atPath: overrideURL.path) ? overrideURL : legacyOverride
        let converted = manager.fileExists(atPath: convertedURL.path) ? try Data(contentsOf: convertedURL) : nil
        let override = manager.fileExists(atPath: effectiveOverride.path) ? try Data(contentsOf: effectiveOverride) : nil
        let assets = try assetFiles(id: id).map { GeneratedAsset(relativePath: $0.name, data: $0.data) }
        return RawRestoreState(converted: converted, override: override, assets: assets)
    }

    private func rawRestoreIdentity(_ state: RawRestoreState) -> RawRestoreIdentity {
        RawRestoreIdentity(convertedHash: state.converted?.sha256String, overrideHash: state.override?.sha256String,
                           assets: state.assets.sorted { $0.relativePath < $1.relativePath }.map {
                            ModuleVersionAsset(path: $0.relativePath, contentHash: $0.data.sha256String, byteCount: $0.data.count)
                           })
    }

    private func rawRestoreFingerprint(_ state: RawRestoreState) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(rawRestoreIdentity(state)).sha256String
    }

    private func currentVersionState(from state: RawRestoreState, id: UUID, reason: ModuleVersionReason) throws -> ModuleVersionCurrentState {
        let assets = rawRestoreIdentity(state).assets
        guard let effective = state.override ?? state.converted else {
            return ModuleVersionCurrentState(content: nil,
                fingerprint: assets.isEmpty ? ModuleVersionRecord.missingFingerprint : "raw:" + (try rawRestoreFingerprint(state)),
                assets: assets, problem: assets.isEmpty ? nil : "当前正文缺失，但仍有脚本资源；恢复前会保留原始文件。")
        }
        guard let text = String(data: effective, encoding: .utf8),
              state.converted == nil || String(data: state.converted!, encoding: .utf8) != nil else {
            return ModuleVersionCurrentState(content: nil, fingerprint: "raw:" + (try rawRestoreFingerprint(state)), assets: assets,
                problem: "当前正文损坏，无法按 UTF-8 读取；历史仍可恢复，损坏原始文件将单独保留。")
        }
        let converted = state.converted.flatMap { String(data: $0, encoding: .utf8) }.map(SurgeModuleSanitizer.sanitize)
        let content = try makeVersionContent(id: id, content: SurgeModuleSanitizer.sanitize(text), converted: converted,
                                             hasOverride: state.override != nil, assets: state.assets, reason: reason)
        return ModuleVersionCurrentState(content: content, fingerprint: content.record.fingerprint, assets: assets, problem: nil)
    }

    private func writeRestoreBundle(_ state: RawRestoreState, id: UUID, at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let converted = state.converted { try writeRestoreData(converted, to: root.appending(path: "Content.cache")) }
        if let override = state.override { try writeRestoreData(override, to: root.appending(path: "Override.module")) }
        let assetsRoot = root.appending(path: "Assets", directoryHint: .isDirectory)
        try stageAssets(state.assets, id: id, at: assetsRoot)
        let prefix = "assets/\(id.uuidString.lowercased())/"
        for asset in state.assets {
            try synchronizeRestoreFile(try exportURL(root: assetsRoot, relativePath: String(asset.relativePath.dropFirst(prefix.count))))
        }
        try writeRestoreData(JSONEncoder().encode(rawRestoreIdentity(state)), to: root.appending(path: "Bundle.json"))
    }

    private func readRestoreBundle(id: UUID, at root: URL) throws -> RawRestoreState {
        let identity = try JSONDecoder().decode(RawRestoreIdentity.self, from: Data(contentsOf: root.appending(path: "Bundle.json")))
        func data(_ name: String, expected: String?) throws -> Data? {
            guard let expected else { return nil }
            let data = try Data(contentsOf: root.appending(path: name))
            guard data.sha256String == expected else { throw RelayError.invalidOutput("恢复事务中的文件校验失败。") }
            return data
        }
        guard Set(identity.assets.map(\.path)).count == identity.assets.count else { throw RelayError.invalidOutput("恢复事务包含重复脚本路径。") }
        let prefix = "assets/\(id.uuidString.lowercased())/"
        var assets: [GeneratedAsset] = []
        for asset in identity.assets {
            guard asset.path.hasPrefix(prefix) else { throw RelayError.invalidOutput("恢复事务脚本路径无效。") }
            let url = try exportURL(root: root.appending(path: "Assets", directoryHint: .isDirectory), relativePath: String(asset.path.dropFirst(prefix.count)))
            let bytes = try Data(contentsOf: url)
            guard bytes.sha256String == asset.contentHash, bytes.count == asset.byteCount else { throw RelayError.invalidOutput("恢复事务中的脚本校验失败。") }
            assets.append(GeneratedAsset(relativePath: asset.path, data: bytes))
        }
        return RawRestoreState(converted: try data("Content.cache", expected: identity.convertedHash),
                               override: try data("Override.module", expected: identity.overrideHash), assets: assets)
    }

    private func writeRestoreData(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try synchronizeRestoreFile(url)
    }

    private func synchronizeRestoreFile(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func installRawRestoreState(_ state: RawRestoreState, id: UUID, recovery: Bool) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: overrideDirectory, withIntermediateDirectories: true)
        let staging = snapshotDirectory.appending(path: ".restore-apply-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        if let converted = state.converted { try writeRestoreData(converted, to: staging.appending(path: "Content.cache")) }
        try stageAssets(state.assets, id: id, at: staging.appending(path: "Assets", directoryHint: .isDirectory))
        let destination = snapshotURL(for: id)
        if !recovery {
            if let override = state.override { try writeRestoreData(override, to: componentOverrideURL(for: id)) }
            else if manager.fileExists(atPath: componentOverrideURL(for: id).path) { try manager.removeItem(at: componentOverrideURL(for: id)) }
            try restoreCheckpoint(.overrideInstalled)
        }
        if manager.fileExists(atPath: destination.path) { _ = try manager.replaceItemAt(destination, withItemAt: staging) }
        else { try manager.moveItem(at: staging, to: destination) }
        try restoreCheckpoint(recovery ? .recoverySnapshotInstalled : .snapshotInstalled)
        if recovery {
            if let override = state.override { try writeRestoreData(override, to: componentOverrideURL(for: id)) }
            else if manager.fileExists(atPath: componentOverrideURL(for: id).path) { try manager.removeItem(at: componentOverrideURL(for: id)) }
            try restoreCheckpoint(.recoveryOverrideInstalled)
        }
    }

    private func installVersionContent(_ version: ModuleVersionContent, previous: RawRestoreState, preservesDamagedCurrent: Bool, id: UUID) throws {
        let transactionID = UUID()
        let root = restoreJournalDirectory.appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
            .appending(path: transactionID.uuidString.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var prepared = false
        defer { if !prepared { try? FileManager.default.removeItem(at: root) } }
        let next = RawRestoreState(converted: Data((version.convertedContent ?? version.content).utf8),
                                   override: Data(version.content.utf8), assets: version.assets)
        try writeRestoreBundle(previous, id: id, at: root.appending(path: "Old", directoryHint: .isDirectory))
        try writeRestoreBundle(next, id: id, at: root.appending(path: "New", directoryHint: .isDirectory))
        let journalURL = root.appending(path: "Journal.json")
        var journal = RestoreJournal(id: transactionID, moduleID: id, phase: .prepared, preservesDamagedCurrent: preservesDamagedCurrent)
        let priorMetadataURL = restoreMetadataURL(id: id)
        if FileManager.default.fileExists(atPath: priorMetadataURL.path) {
            journal.previousMetadataPending = try JSONDecoder().decode(RestoreMetadataPending.self, from: Data(contentsOf: priorMetadataURL))
        }
        try writeRestoreData(JSONEncoder().encode(journal), to: journalURL)
        prepared = true
        do {
            try markCombinedForRebuild()
            try restoreCheckpoint(.prepared)
            try installRawRestoreState(next, id: id, recovery: false)
            guard try rawRestoreFingerprint(captureRawRestoreState(id: id)) == rawRestoreFingerprint(next) else {
                throw RelayError.invalidOutput("恢复安装后的正文或脚本校验失败。")
            }
            try markRestoreMetadataPending(journal)
            try restoreCheckpoint(.metadataPending)
            journal.phase = .committed
            try writeRestoreData(JSONEncoder().encode(journal), to: journalURL)
            try restoreCheckpoint(.committed)
            try finalizeRestoreJournal(&journal, at: root)
            try restoreCheckpoint(.finalized)
            try? FileManager.default.removeItem(at: root)
        } catch {
            if error is InjectedRestoreInterruption { throw error }
            let original = error
            do { try recoverInterruptedRestore(id: id) }
            catch { throw RelayError.invalidOutput("版本恢复被中断，事务已保留，缓存将在读取前重试恢复：\(error.localizedDescription)") }
            throw original
        }
    }

    private func finalizeRestoreJournal(_ journal: inout RestoreJournal, at root: URL) throws {
        if journal.phase == .committed { try markRestoreMetadataPending(journal) }
        if journal.phase == .prepared {
            let url = restoreMetadataURL(id: journal.moduleID)
            if let data = try? Data(contentsOf: url),
               let pending = try? JSONDecoder().decode(RestoreMetadataPending.self, from: data),
               pending.transactionID == journal.id {
                if let previous = journal.previousMetadataPending {
                    try writeRestoreData(JSONEncoder().encode(previous), to: url)
                } else {
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
        if journal.phase == .committed, journal.preservesDamagedCurrent {
            let backup = storageConfigurationDirectory.appending(path: "Backups/DamagedModule/\(journal.moduleID.uuidString.lowercased())/\(journal.id.uuidString.lowercased())", directoryHint: .isDirectory)
            if !FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: root.appending(path: "Old"), to: backup)
            }
        }
        journal.phase = .finalized
        try writeRestoreData(JSONEncoder().encode(journal), to: root.appending(path: "Journal.json"))
        if journal.preservesDamagedCurrent {
            let backups = storageConfigurationDirectory.appending(path: "Backups/DamagedModule/\(journal.moduleID.uuidString.lowercased())", directoryHint: .isDirectory)
            let entries = (try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: [.creationDateKey])) ?? []
            let ordered = entries.filter { UUID(uuidString: $0.lastPathComponent) != nil }.sorted {
                if $0 == $1 { return false }
                if $0.lastPathComponent == journal.id.uuidString.lowercased() { return true }
                if $1.lastPathComponent == journal.id.uuidString.lowercased() { return false }
                return ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
            }
            for old in ordered.dropFirst(5) { try? FileManager.default.removeItem(at: old) }
        }
    }

    private func recoverInterruptedRestore(id: UUID) throws {
        guard !recoveringRestores.contains(id) else { return }
        let root = restoreJournalDirectory.appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        recoveringRestores.insert(id)
        defer { recoveringRestores.remove(id) }
        for transaction in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            guard UUID(uuidString: transaction.lastPathComponent) != nil else { continue }
            let journalURL = transaction.appending(path: "Journal.json")
            guard FileManager.default.fileExists(atPath: journalURL.path) else {
                try? FileManager.default.removeItem(at: transaction)
                continue
            }
            var journal = try JSONDecoder().decode(RestoreJournal.self, from: Data(contentsOf: journalURL))
            guard journal.moduleID == id, journal.id.uuidString.lowercased() == transaction.lastPathComponent.lowercased() else {
                throw RelayError.invalidOutput("恢复事务归属无效，未读取可能不一致的缓存。")
            }
            if journal.phase != .finalized {
                try markCombinedForRebuild()
                let state = try readRestoreBundle(id: id, at: transaction.appending(path: journal.phase == .prepared ? "Old" : "New"))
                try installRawRestoreState(state, id: id, recovery: true)
                guard try rawRestoreFingerprint(captureRawRestoreState(id: id)) == rawRestoreFingerprint(state) else {
                    throw RelayError.invalidOutput("恢复事务未能安装一致的正文和脚本。")
                }
                try finalizeRestoreJournal(&journal, at: transaction)
            }
            try? FileManager.default.removeItem(at: transaction)
        }
    }

    func prepareConversion(_ result: ConversionResult, id: UUID) throws -> (converted: String, effective: String, hasOverride: Bool) {
        let converted = SurgeModuleSanitizer.sanitize(result.content)
        let hasOverride = hasOverride(id: id)
        return (converted, hasOverride ? try readComponent(id: id) : converted, hasOverride)
    }

    func hasComponent(id: UUID) -> Bool {
        do { try recoverInterruptedRestore(id: id) } catch { return false }
        let legacyURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Surge Relay/Components/\(id.uuidString).sgmodule")
        return FileManager.default.fileExists(atPath: componentOverrideURL(for: id).path)
            || FileManager.default.fileExists(atPath: componentURL(for: id).path)
            || (!AppRuntimeOptions.isUIQAMode && allowsLegacyFallback && FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func hasOverride(id: UUID) -> Bool {
        do { try recoverInterruptedRestore(id: id) } catch { return false }
        return FileManager.default.fileExists(atPath: componentOverrideURL(for: id).path)
    }

    func readComponent(id: UUID) throws -> String {
        try recoverInterruptedRestore(id: id)
        let overrideURL = componentOverrideURL(for: id)
        let legacyOverrideURL = cacheDirectory
            .appending(path: "Overrides/\(id.uuidString).cache")
        if !FileManager.default.fileExists(atPath: overrideURL.path),
           FileManager.default.fileExists(atPath: legacyOverrideURL.path) {
            try FileManager.default.createDirectory(at: overrideDirectory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: legacyOverrideURL, to: overrideURL)
        }
        if FileManager.default.fileExists(atPath: overrideURL.path) {
            return SurgeModuleSanitizer.sanitize(try decodeText(at: overrideURL))
        }
        return try readConvertedComponent(id: id)
    }

    func readConvertedComponent(id: UUID) throws -> String {
        try recoverInterruptedRestore(id: id)
        let url = componentURL(for: id)
        if !FileManager.default.fileExists(atPath: url.path) {
            let legacyURL = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/Surge Relay/Components/\(id.uuidString).sgmodule")
            if !AppRuntimeOptions.isUIQAMode, allowsLegacyFallback, FileManager.default.fileExists(atPath: legacyURL.path) {
                try FileManager.default.createDirectory(at: componentDirectory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: legacyURL, to: url)
            }
        }
        return SurgeModuleSanitizer.sanitize(try decodeText(at: url))
    }

    func writeComponentOverride(_ content: String, id: UUID) throws {
        try recoverInterruptedRestore(id: id)
        try FileManager.default.createDirectory(at: overrideDirectory, withIntermediateDirectories: true)
        try PersistenceStore.writeProtectedData(
            Data(SurgeModuleSanitizer.sanitize(content).utf8),
            to: componentOverrideURL(for: id),
            configurationDirectory: storageConfigurationDirectory
        )
    }

    func removeComponentOverride(id: UUID) throws {
        try recoverInterruptedRestore(id: id)
        let url = componentOverrideURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func removeComponent(id: UUID) throws {
        try recoverInterruptedRestore(id: id)
        for url in [snapshotURL(for: id), componentDirectory.appending(path: "\(id.uuidString).cache")] {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        let overrideURL = componentOverrideURL(for: id)
        if FileManager.default.fileExists(atPath: overrideURL.path) { try FileManager.default.removeItem(at: overrideURL) }
        let pending = restoreMetadataURL(id: id)
        if FileManager.default.fileExists(atPath: pending.path) { try FileManager.default.removeItem(at: pending) }
    }

    func writeCombined(_ content: String) throws {
        try FileManager.default.createDirectory(at: combinedCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: combinedCacheURL, options: .atomic)
        if FileManager.default.fileExists(atPath: combinedRebuildMarkerURL.path) { try FileManager.default.removeItem(at: combinedRebuildMarkerURL) }
    }

    func readCombined() throws -> Data {
        guard try !recoverInterruptedVersionRestores() else {
            throw RelayError.invalidOutput("版本恢复后尚未完成元数据确认或总模块重建，请先完成恢复。")
        }
        let url = FileManager.default.fileExists(atPath: combinedOverrideURL.path) ? combinedOverrideURL : combinedCacheURL
        return try Data(contentsOf: url)
    }

    func exportPublishedFiles(
        _ files: [PublishFile],
        toRootDirectory rootDirectoryPath: String,
        removingObsoleteRelativePaths obsoleteRelativePaths: [String] = [],
        knownManagedRelativePaths: [String] = [],
        expectedExistingHashes: [String: String] = [:]
    ) throws -> [String] {
        let root = URL(filePath: rootDirectoryPath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let currentPaths = Set(files.map(\.name))
        let recoveredPaths = try recoverPublishedResourcePaths(rootDirectoryPath: rootDirectoryPath)
        let receiptPaths = try verifiedResourceReceiptPaths(root: canonicalResourceRoot(root), paths: currentPaths.union(obsoleteRelativePaths))
        let knownManagedPaths = Set((knownManagedRelativePaths + recoveredPaths + receiptPaths).map(Self.normalizedRelativePath))
        var removedPaths: [String] = []

        var writtenPaths: [String] = []
        do {
            for relativePath in obsoleteRelativePaths where !currentPaths.contains(relativePath) {
                let destination = try exportURL(root: root, relativePath: relativePath)
                let existed = FileManager.default.fileExists(atPath: destination.path)
                if !existed, let expected = expectedExistingHashes[relativePath], expected != "<missing>" {
                    throw RelayError.invalidOutput("本地文件在清理预览后发生变化，请重新预览。")
                }
                if existed {
                    try removeManagedPublishedFile(at: destination, relativePath: relativePath,
                                                   isKnownManagedPath: knownManagedPaths.contains(Self.normalizedRelativePath(relativePath)),
                                                   expectedExistingHash: expectedExistingHashes[relativePath])
                    if existed {
                        removedPaths.append(relativePath)
                        try removeEmptyParentDirectories(startingAt: destination.deletingLastPathComponent(), root: root)
                    }
                }
            }

            for file in files {
                let destination = try exportURL(root: root, relativePath: file.name)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try writeManagedPublishedFile(
                    file.data,
                    to: destination,
                    relativePath: file.name,
                    rootDirectory: root,
                    isKnownManagedPath: knownManagedPaths.contains(Self.normalizedRelativePath(file.name)),
                    expectedExistingHash: expectedExistingHashes[file.name]
                )
                writtenPaths.append(file.name)
            }
        } catch {
            guard !writtenPaths.isEmpty else { throw error }
            throw LocalPublishPartialFailure(underlyingError: error, writtenPaths: writtenPaths)
        }
        return removedPaths
    }

    func removeCombined() throws {
        if FileManager.default.fileExists(atPath: combinedCacheURL.path) {
            try FileManager.default.removeItem(at: combinedCacheURL)
        }
        if FileManager.default.fileExists(atPath: combinedOverrideURL.path) {
            try FileManager.default.removeItem(at: combinedOverrideURL)
        }
        if FileManager.default.fileExists(atPath: combinedRebuildMarkerURL.path) { try FileManager.default.removeItem(at: combinedRebuildMarkerURL) }
    }

    func replaceAssets(_ assets: [GeneratedAsset], id: UUID) throws {
        try recoverInterruptedRestore(id: id)
        let manager = FileManager.default
        let root = assetsURL(for: id)
        try manager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = root.deletingLastPathComponent().appending(path: ".assets-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? manager.removeItem(at: staging) }
        try stageAssets(assets, id: id, at: staging)
        if manager.fileExists(atPath: root.path) {
            _ = try manager.replaceItemAt(root, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: root)
        }
    }

    func removeAssets(id: UUID) throws {
        try recoverInterruptedRestore(id: id)
        let root = assetsURL(for: id)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func generatedAssetFiles(for moduleIDs: Set<UUID>? = nil) throws -> [PublishFile] {
        let ids: Set<UUID>
        if let moduleIDs { ids = moduleIDs }
        else {
            let directories = [assetDirectory, snapshotDirectory].flatMap {
                (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? []
            }
            ids = Set(directories.compactMap(UUID.init(uuidString:)))
        }
        var files: [PublishFile] = []
        for id in ids {
            try recoverInterruptedRestore(id: id)
            files.append(contentsOf: try assetFiles(id: id))
        }
        return files.sorted { $0.name < $1.name }
    }

    private func assetFiles(id: UUID) throws -> [PublishFile] {
        let root = assetsURL(for: id).resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var files: [PublishFile] = []
        for case let fileURL as URL in enumerator {
            guard try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let relative = String(fileURL.standardizedFileURL.path.dropFirst(root.path.count + 1))
            files.append(PublishFile(name: "assets/\(id.uuidString.lowercased())/\(relative)", data: try Data(contentsOf: fileURL)))
        }
        return files.sorted { $0.name < $1.name }
    }

    private func stageAssets(_ assets: [GeneratedAsset], id: UUID, at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prefix = "assets/\(id.uuidString.lowercased())/"
        var paths: Set<String> = []
        for asset in assets {
            guard asset.relativePath.hasPrefix(prefix) else { throw RelayError.invalidOutput("生成脚本的保存路径无效。") }
            let relative = String(asset.relativePath.dropFirst(prefix.count))
            let destination = try exportURL(root: root, relativePath: relative)
            guard paths.insert(destination.path.lowercased()).inserted else { throw RelayError.invalidOutput("生成脚本包含重复保存路径。") }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try asset.data.write(to: destination)
        }
    }

    func removeLegacyPublishedFiles(in directoryPath: String, relativePaths: [String]) throws -> [String] {
        let directory = URL(filePath: directoryPath, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var removedPaths: [String] = []
        for relativePath in Set(relativePaths).sorted() {
            let destination = try exportURL(root: directory, relativePath: relativePath)
            guard FileManager.default.fileExists(atPath: destination.path) else { continue }
            try FileManager.default.removeItem(at: destination)
            removedPaths.append(relativePath)
            try removeEmptyParentDirectories(startingAt: destination.deletingLastPathComponent(), root: directory)
        }
        return removedPaths
    }

    private func componentURL(for id: UUID) -> URL {
        let snapshot = snapshotURL(for: id)
        if FileManager.default.fileExists(atPath: snapshot.path) {
            return snapshot.appending(path: "Content.cache")
        }
        return componentDirectory.appending(path: "\(id.uuidString).cache")
    }

    private func snapshotURL(for id: UUID) -> URL {
        snapshotDirectory.appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    private func assetsURL(for id: UUID) -> URL {
        let snapshot = snapshotURL(for: id)
        return FileManager.default.fileExists(atPath: snapshot.path)
            ? snapshot.appending(path: "Assets", directoryHint: .isDirectory)
            : assetDirectory.appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    private func componentOverrideURL(for id: UUID) -> URL {
        overrideDirectory.appending(path: "\(id.uuidString).module")
    }

    /// 安全删除一个已发布的本地独立文件。只有当文件带有 Surge Relay 管理标记时
    /// 才会被删除；自写模块的用户源文件不属于管理对象，会被保留，避免误删。
    func removePublishedFile(relativePath: String, rootDirectoryPath: String) throws {
        guard !relativePath.isEmpty,
              !rootDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let root = URL(filePath: rootDirectoryPath, directoryHint: .isDirectory)
        let destination = try exportURL(root: root, relativePath: relativePath)
        if FileManager.default.fileExists(atPath: destination.path) {
            try removeManagedPublishedFile(at: destination, relativePath: relativePath)
        }
    }

    func readPublishedFile(relativePath: String, rootDirectoryPath: String) throws -> Data? {
        guard !relativePath.isEmpty,
              !rootDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let root = URL(filePath: rootDirectoryPath, directoryHint: .isDirectory)
        let destination = try exportURL(root: root, relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: destination.path) else { return nil }
        return try Data(contentsOf: destination)
    }

    /// 强制删除一个已发布的本地独立文件（无论是否带 Surge Relay 管理标记）。
    /// 仅用于用户明确确认“彻底删除（含源文件）”的场景。
    func removePublishedFileForcing(relativePath: String, rootDirectoryPath: String) throws {
        guard !relativePath.isEmpty,
              !rootDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let root = URL(filePath: rootDirectoryPath, directoryHint: .isDirectory)
        let destination = try exportURL(root: root, relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        let outcome = CoordinationOutcome<Void>()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        coordinator.coordinate(
            writingItemAt: destination,
            options: .forDeleting,
            error: &coordinationError
        ) { coordinatedURL in
            outcome.result = Result { try FileManager.default.removeItem(at: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        try outcome.result?.get()
    }

    private func exportURL(root: URL, relativePath: String) throws -> URL {
        let components = relativePath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RelayError.invalidOutput("发布路径无效。")
        }

        var url = root
        for component in components.dropLast() {
            url = url.appending(path: component, directoryHint: .isDirectory)
        }
        return url.appending(path: components[components.count - 1])
    }

    private struct ResourceIdentity: Codable, Equatable {
        var device: UInt64
        var inode: UInt64
        var birthTime: TimeInterval
    }

    private struct PublishedResourceJournal: Codable {
        var id: UUID
        var rootPath: String
        var rootIdentity: ResourceIdentity
        var relativePath: String
        var stagedIdentity: ResourceIdentity
        var contentHash: String
    }

    private struct InjectedResourceInterruption: Error { var underlying: any Error }

    private var publishedResourceJournalDirectory: URL {
        storageConfigurationDirectory.appending(path: "PublishedResourceTransactions", directoryHint: .isDirectory)
    }

    private var publishedResourceOwnershipDirectory: URL {
        storageConfigurationDirectory.appending(path: "PublishedResourceOwnership", directoryHint: .isDirectory)
    }

    private func resourceReceiptScope(rootPath: String, identity: ResourceIdentity) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data(rootPath.utf8)
        data.append(0)
        data.append(try encoder.encode(identity))
        return publishedResourceOwnershipDirectory.appending(path: data.sha256String, directoryHint: .isDirectory)
    }

    private func resourceReceiptURL(_ journal: PublishedResourceJournal) throws -> URL {
        try resourceReceiptScope(rootPath: journal.rootPath, identity: journal.rootIdentity)
            .appending(path: Data(journal.relativePath.utf8).sha256String + ".json")
    }

    private func persistResourceReceipt(_ journal: PublishedResourceJournal) throws {
        let url = try resourceReceiptURL(journal)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeRestoreData(JSONEncoder().encode(journal), to: url)
    }

    private func verifiedResourceReceiptPaths(root: URL, paths requestedPaths: Set<String>) throws -> [String] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let identity = try resourceIdentity(at: root)
        let directory = try resourceReceiptScope(rootPath: root.path, identity: identity)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var paths: [String] = []
        let candidates = requestedPaths.map { directory.appending(path: Data($0.utf8).sha256String + ".json") }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            let receipt = try JSONDecoder().decode(PublishedResourceJournal.self, from: Data(contentsOf: url))
            guard receipt.rootPath == root.path, receipt.rootIdentity == identity,
                  !ManagedPublishedFile.requiresInlineMarker(receipt.relativePath),
                  try resourceReceiptURL(receipt) == url else { throw RelayError.invalidOutput("资源归属凭据无效。") }
            let destination = try exportURL(root: root, relativePath: receipt.relativePath)
            if matchesResource(destination, journal: receipt) { paths.append(receipt.relativePath) }
        }
        return paths
    }

    private func resourceIdentity(at url: URL) throws -> ResourceIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let createdAt = attributes[.creationDate] as? Date else {
            throw RelayError.invalidOutput("无法取得本地资源文件身份，未记录归属。")
        }
        return ResourceIdentity(device: device.uint64Value, inode: inode.uint64Value, birthTime: createdAt.timeIntervalSinceReferenceDate)
    }

    private func canonicalResourceRoot(_ root: URL) -> URL { root.resolvingSymlinksInPath().standardizedFileURL }

    private func resourceJournalURL(_ id: UUID) -> URL {
        publishedResourceJournalDirectory.appending(path: id.uuidString.lowercased() + ".json")
    }

    private func resourceStageURL(_ journal: PublishedResourceJournal, destination: URL) -> URL {
        destination.deletingLastPathComponent().appending(path: ".surge-relay-\(journal.id.uuidString.lowercased()).stage")
    }

    private func resourceCheckpoint(_ phase: PublishedResourcePhase) throws {
        do { try resourceInterruption?(phase) }
        catch { throw InjectedResourceInterruption(underlying: error) }
    }

    private func resourceJournals(rootDirectory: URL) throws -> [PublishedResourceJournal] {
        guard FileManager.default.fileExists(atPath: rootDirectory.path),
              FileManager.default.fileExists(atPath: publishedResourceJournalDirectory.path) else { return [] }
        let root = canonicalResourceRoot(rootDirectory)
        let identity = try resourceIdentity(at: root)
        var journals: [PublishedResourceJournal] = []
        for url in try FileManager.default.contentsOfDirectory(at: publishedResourceJournalDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            let journal = try JSONDecoder().decode(PublishedResourceJournal.self, from: Data(contentsOf: url))
            guard journal.id == id else { throw RelayError.invalidOutput("本地资源恢复记录身份无效。") }
            guard journal.rootPath == root.path, journal.rootIdentity == identity else { continue }
            guard !ManagedPublishedFile.requiresInlineMarker(journal.relativePath) else { throw RelayError.invalidOutput("本地资源恢复记录类型无效。") }
            _ = try exportURL(root: root, relativePath: journal.relativePath)
            journals.append(journal)
        }
        return journals
    }

    private func matchesResourceIdentity(_ url: URL, journal: PublishedResourceJournal) -> Bool {
        (try? resourceIdentity(at: url)) == journal.stagedIdentity
    }

    private func matchesResource(_ url: URL, journal: PublishedResourceJournal) -> Bool {
        guard matchesResourceIdentity(url, journal: journal), let data = try? Data(contentsOf: url) else { return false }
        return data.sha256String == journal.contentHash
    }

    func recoverPublishedResourcePaths(rootDirectoryPath: String) throws -> [String] {
        let root = canonicalResourceRoot(URL(filePath: rootDirectoryPath, directoryHint: .isDirectory))
        let journals = try resourceJournals(rootDirectory: root)
        var paths: Set<String> = []
        for journal in journals {
            let destination = try exportURL(root: root, relativePath: journal.relativePath)
            if matchesResource(destination, journal: journal) { paths.insert(journal.relativePath) }
        }
        return paths.sorted()
    }

    func acknowledgePublishedResources(paths: [String], rootDirectoryPath: String) throws {
        let root = canonicalResourceRoot(URL(filePath: rootDirectoryPath, directoryHint: .isDirectory))
        let journals = try resourceJournals(rootDirectory: root)
        let requested = Set(paths)
        var current: [String: PublishedResourceJournal] = [:]
        for journal in journals where requested.contains(journal.relativePath) {
            let destination = try exportURL(root: root, relativePath: journal.relativePath)
            if matchesResource(destination, journal: journal) { current[journal.relativePath] = journal }
        }
        let verified = Set(current.keys).union(try verifiedResourceReceiptPaths(root: root, paths: requested)).intersection(requested)
        try resourceCheckpoint(.acknowledging)
        for journal in current.values { try persistResourceReceipt(journal) }
        try resourceCheckpoint(.ownershipPersisted)
        for journal in journals where verified.contains(journal.relativePath) {
            let destination = try exportURL(root: root, relativePath: journal.relativePath)
            let stage = resourceStageURL(journal, destination: destination)
            if matchesResourceIdentity(stage, journal: journal) { try FileManager.default.removeItem(at: stage) }
            try FileManager.default.removeItem(at: resourceJournalURL(journal.id))
            try resourceCheckpoint(.journalRemoved)
        }
        try resourceCheckpoint(.acknowledged)
    }

    private func discardUnpublishedResourceStages(root: URL, relativePath: String) throws {
        for journal in try resourceJournals(rootDirectory: root) where journal.relativePath == relativePath {
            let destination = try exportURL(root: root, relativePath: relativePath)
            let stage = resourceStageURL(journal, destination: destination)
            if matchesResourceIdentity(stage, journal: journal), !matchesResource(destination, journal: journal) {
                try FileManager.default.removeItem(at: stage)
                try FileManager.default.removeItem(at: resourceJournalURL(journal.id))
            }
        }
    }

    private func writePublishedResource(_ data: Data, at destination: URL, relativePath: String, rootDirectory: URL) throws {
        let root = canonicalResourceRoot(rootDirectory)
        try discardUnpublishedResourceStages(root: root, relativePath: relativePath)
        let id = UUID()
        let initialHash = (try? Data(contentsOf: destination))?.sha256String ?? "<missing>"
        let stage = destination.deletingLastPathComponent().appending(path: ".surge-relay-\(id.uuidString.lowercased()).stage")
        let descriptor = stage.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { try? handle.close() }
        var journalWritten = false
        do {
            let journal = PublishedResourceJournal(id: id, rootPath: root.path, rootIdentity: try resourceIdentity(at: root),
                relativePath: relativePath, stagedIdentity: try resourceIdentity(at: stage), contentHash: data.sha256String)
            try FileManager.default.createDirectory(at: publishedResourceJournalDirectory, withIntermediateDirectories: true)
            try writeRestoreData(JSONEncoder().encode(journal), to: resourceJournalURL(id))
            journalWritten = true
            try resourceCheckpoint(.journalPrepared)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try resourceCheckpoint(.staged)
            guard matchesResource(stage, journal: journal) else { throw RelayError.invalidOutput("本地资源暂存内容校验失败。") }
            let currentHash = (try? Data(contentsOf: destination))?.sha256String ?? "<missing>"
            guard currentHash == initialHash else { throw RelayError.invalidOutput("本地资源在写入准备期间变化，请重新预览。") }
            try resourceCheckpoint(.beforeRename)
            let finalHash = (try? Data(contentsOf: destination))?.sha256String ?? "<missing>"
            guard finalHash == initialHash else { throw RelayError.invalidOutput("本地资源在提交前变化，请重新预览。") }
            let code = stage.path.withCString { source in destination.path.withCString { target in
                initialHash == "<missing>" ? Darwin.renamex_np(source, target, UInt32(RENAME_EXCL)) : Darwin.rename(source, target)
            } }
            guard code == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            guard matchesResource(destination, journal: journal) else {
                throw RelayError.invalidOutput("本地资源写入后的身份或内容校验失败，请核对目标。")
            }
            try resourceCheckpoint(.renamed)
        } catch {
            if !(error is InjectedResourceInterruption), !journalWritten { try? FileManager.default.removeItem(at: stage) }
            throw error
        }
    }

    private func writeManagedPublishedFile(
        _ data: Data,
        to destination: URL,
        relativePath: String,
        rootDirectory: URL,
        isKnownManagedPath: Bool,
        expectedExistingHash: String? = nil
    ) throws {
        let managedData = ManagedPublishedFile.dataWrapping(data, relativePath: relativePath)
        let outcome = CoordinationOutcome<Void>()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        coordinator.coordinate(
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            outcome.result = Result {
                if let expectedExistingHash {
                    let actualHash = (try? Data(contentsOf: coordinatedURL))?.sha256String ?? "<missing>"
                    guard actualHash == expectedExistingHash else {
                        throw RelayError.invalidOutput("本地文件在比较后发生变化，请重新比较后确认。")
                    }
                }
                let conflictVersions = try ManagedPublishedFile.validatedConflictVersions(
                    at: coordinatedURL,
                    allowingKnownManagedPath: isKnownManagedPath,
                    relativePath: relativePath
                )
                if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                    let existing = try Data(contentsOf: coordinatedURL)
                    guard ManagedPublishedFile.isManaged(existing, relativePath: relativePath) || isKnownManagedPath else {
                        throw RelayError.invalidOutput(
                            "目标文件 \(relativePath) 已存在且不属于 Surge Relay 管理，已停止写入。"
                        )
                    }
                    if conflictVersions.isEmpty, existing == managedData {
                        return
                    }
                }
                if ManagedPublishedFile.requiresInlineMarker(relativePath) {
                    try managedData.write(to: coordinatedURL, options: .atomic)
                } else {
                    try writePublishedResource(managedData, at: coordinatedURL, relativePath: relativePath, rootDirectory: rootDirectory)
                }
                try ManagedPublishedFile.resolve(conflictVersions, at: coordinatedURL)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result = outcome.result else {
            throw RelayError.invalidOutput("iCloud 未能完成 \(relativePath) 写入协调。")
        }
        try result.get()
    }

    private func removeManagedPublishedFile(at url: URL, relativePath: String, isKnownManagedPath: Bool = false, expectedExistingHash: String? = nil) throws {
        let outcome = CoordinationOutcome<Void>()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        coordinator.coordinate(
            writingItemAt: url,
            options: .forDeleting,
            error: &coordinationError
        ) { coordinatedURL in
            outcome.result = Result {
                if let expectedExistingHash {
                    let actualHash = (try? Data(contentsOf: coordinatedURL))?.sha256String ?? "<missing>"
                    guard actualHash == expectedExistingHash else {
                        throw RelayError.invalidOutput("本地文件在清理预览后发生变化，请重新预览。")
                    }
                }
                guard FileManager.default.fileExists(atPath: coordinatedURL.path) else { return }
                let existing = try Data(contentsOf: coordinatedURL)
                let manifestOwnsResource = isKnownManagedPath && !ManagedPublishedFile.requiresInlineMarker(relativePath)
                guard ManagedPublishedFile.isManaged(existing, relativePath: relativePath) || manifestOwnsResource else {
                    throw RelayError.invalidOutput(
                        "旧文件 \(relativePath) 不属于 Surge Relay 管理，已停止自动清理。"
                    )
                }
                let conflictVersions = try ManagedPublishedFile.validatedConflictVersions(
                    at: coordinatedURL,
                    allowingKnownManagedPath: manifestOwnsResource,
                    relativePath: relativePath
                )
                try ManagedPublishedFile.resolve(conflictVersions, at: coordinatedURL)
                try FileManager.default.removeItem(at: coordinatedURL)
            }
        }
        if let coordinationError { throw coordinationError }
        try outcome.result?.get()
    }

    private func removeEmptyParentDirectories(startingAt directory: URL, root: URL) throws {
        var current = directory
        while current.path != root.path, current.path.hasPrefix(root.path + "/") {
            let contents = try FileManager.default.contentsOfDirectory(atPath: current.path)
            guard contents.isEmpty else { return }
            try FileManager.default.removeItem(at: current)
            current.deleteLastPathComponent()
        }
    }

    private func decodeText(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) else {
            throw RelayError.invalidOutput("模块缓存不是有效的 UTF-8 文本。")
        }
        return content
    }

    private nonisolated static func normalizedRelativePath(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "/")
            .lowercased()
    }

}
