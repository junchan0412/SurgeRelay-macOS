import Foundation

actor ModuleFileStore {
    private let cacheRoot: URL?
    private let configurationRoot: URL?

    init(cacheDirectory: URL? = nil, configurationDirectory: URL? = nil) {
        cacheRoot = cacheDirectory
        configurationRoot = configurationDirectory
    }

    private var cacheDirectory: URL { cacheRoot ?? PersistenceStore.cacheDirectoryURL }
    private var snapshotDirectory: URL { cacheDirectory.appending(path: "Snapshots", directoryHint: .isDirectory) }
    private final class CoordinationOutcome<Value>: @unchecked Sendable {
        var result: Result<Value, Error>?
    }

    private var componentDirectory: URL {
        cacheDirectory.appending(path: "Components", directoryHint: .isDirectory)
    }

    private var overrideDirectory: URL {
        (configurationRoot ?? PersistenceStore.configurationDirectoryURL).appending(path: "Overrides", directoryHint: .isDirectory)
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

    func writeComponent(_ content: String, id: UUID) throws {
        try FileManager.default.createDirectory(at: componentDirectory, withIntermediateDirectories: true)
        try Data(SurgeModuleSanitizer.sanitize(content).utf8).write(to: componentURL(for: id), options: .atomic)
    }

    func commitConversion(_ result: ConversionResult, id: UUID) throws {
        try Task.checkCancellation()
        let manager = FileManager.default
        try manager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        let staging = snapshotDirectory.appending(path: ".\(id.uuidString)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        try Data(SurgeModuleSanitizer.sanitize(result.content).utf8).write(to: staging.appending(path: "Content.cache"))
        try stageAssets(result.assets, id: id, at: staging.appending(path: "Assets", directoryHint: .isDirectory))
        try Task.checkCancellation()
        let destination = snapshotURL(for: id)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
    }

    func prepareConversion(_ result: ConversionResult, id: UUID) throws -> (converted: String, effective: String, hasOverride: Bool) {
        let converted = SurgeModuleSanitizer.sanitize(result.content)
        let hasOverride = hasOverride(id: id)
        return (converted, hasOverride ? try readComponent(id: id) : converted, hasOverride)
    }

    func hasComponent(id: UUID) -> Bool {
        let legacyURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Surge Relay/Components/\(id.uuidString).sgmodule")
        return FileManager.default.fileExists(atPath: componentOverrideURL(for: id).path)
            || FileManager.default.fileExists(atPath: componentURL(for: id).path)
            || (!AppRuntimeOptions.isUIQAMode && cacheRoot == nil && FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func hasOverride(id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: componentOverrideURL(for: id).path)
    }

    func readComponent(id: UUID) throws -> String {
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
        let url = componentURL(for: id)
        if !FileManager.default.fileExists(atPath: url.path) {
            let legacyURL = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/Surge Relay/Components/\(id.uuidString).sgmodule")
            if !AppRuntimeOptions.isUIQAMode, cacheRoot == nil, FileManager.default.fileExists(atPath: legacyURL.path) {
                try FileManager.default.createDirectory(at: componentDirectory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: legacyURL, to: url)
            }
        }
        return SurgeModuleSanitizer.sanitize(try decodeText(at: url))
    }

    func writeComponentOverride(_ content: String, id: UUID) throws {
        try FileManager.default.createDirectory(at: overrideDirectory, withIntermediateDirectories: true)
        try PersistenceStore.writeProtectedData(
            Data(SurgeModuleSanitizer.sanitize(content).utf8),
            to: componentOverrideURL(for: id)
        )
    }

    func removeComponentOverride(id: UUID) throws {
        let url = componentOverrideURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func removeComponent(id: UUID) throws {
        for url in [snapshotURL(for: id), componentDirectory.appending(path: "\(id.uuidString).cache")] {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        let overrideURL = componentOverrideURL(for: id)
        if FileManager.default.fileExists(atPath: overrideURL.path) { try FileManager.default.removeItem(at: overrideURL) }
    }

    func writeCombined(_ content: String) throws {
        try FileManager.default.createDirectory(at: combinedCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: combinedCacheURL, options: .atomic)
    }

    func readCombined() throws -> Data {
        let url = FileManager.default.fileExists(atPath: combinedOverrideURL.path) ? combinedOverrideURL : combinedCacheURL
        return try Data(contentsOf: url)
    }

    func exportPublishedFiles(
        _ files: [PublishFile],
        toRootDirectory rootDirectoryPath: String,
        removingObsoleteRelativePaths obsoleteRelativePaths: [String] = [],
        knownManagedRelativePaths: [String] = []
    ) throws -> [String] {
        let root = URL(filePath: rootDirectoryPath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let currentPaths = Set(files.map(\.name))
        let knownManagedPaths = Set(knownManagedRelativePaths.map(Self.normalizedRelativePath))
        var removedPaths: [String] = []

        for relativePath in obsoleteRelativePaths where !currentPaths.contains(relativePath) {
            let destination = try exportURL(root: root, relativePath: relativePath)
            if FileManager.default.fileExists(atPath: destination.path) {
                try removeManagedPublishedFile(at: destination, relativePath: relativePath)
                removedPaths.append(relativePath)
                try removeEmptyParentDirectories(startingAt: destination.deletingLastPathComponent(), root: root)
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
                isKnownManagedPath: knownManagedPaths.contains(Self.normalizedRelativePath(file.name))
            )
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
    }

    func replaceAssets(_ assets: [GeneratedAsset], id: UUID) throws {
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
            let root = assetsURL(for: id).resolvingSymlinksInPath().standardizedFileURL
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let fileURL as URL in enumerator {
                guard try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                let relative = String(fileURL.standardizedFileURL.path.dropFirst(root.path.count + 1))
                files.append(PublishFile(name: "assets/\(id.uuidString.lowercased())/\(relative)", data: try Data(contentsOf: fileURL)))
            }
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

    private func writeManagedPublishedFile(
        _ data: Data,
        to destination: URL,
        relativePath: String,
        isKnownManagedPath: Bool
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
                let conflictVersions = try ManagedPublishedFile.validatedConflictVersions(
                    at: coordinatedURL,
                    allowingKnownManagedPath: isKnownManagedPath
                )
                if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                    let existing = try Data(contentsOf: coordinatedURL)
                    guard ManagedPublishedFile.isManaged(existing) || isKnownManagedPath else {
                        throw RelayError.invalidOutput(
                            "目标文件 \(relativePath) 已存在且不属于 Surge Relay 管理，已停止写入。"
                        )
                    }
                    if conflictVersions.isEmpty, existing == managedData {
                        return
                    }
                }
                try managedData.write(to: coordinatedURL, options: .atomic)
                try ManagedPublishedFile.resolve(conflictVersions, at: coordinatedURL)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result = outcome.result else {
            throw RelayError.invalidOutput("iCloud 未能完成 \(relativePath) 写入协调。")
        }
        try result.get()
    }

    private func removeManagedPublishedFile(at url: URL, relativePath: String) throws {
        let outcome = CoordinationOutcome<Void>()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        coordinator.coordinate(
            writingItemAt: url,
            options: .forDeleting,
            error: &coordinationError
        ) { coordinatedURL in
            outcome.result = Result {
                guard FileManager.default.fileExists(atPath: coordinatedURL.path) else { return }
                let existing = try Data(contentsOf: coordinatedURL)
                guard ManagedPublishedFile.isManaged(existing) else {
                    throw RelayError.invalidOutput(
                        "旧文件 \(relativePath) 不属于 Surge Relay 管理，已停止自动清理。"
                    )
                }
                let conflictVersions = try ManagedPublishedFile.validatedConflictVersions(
                    at: coordinatedURL,
                    allowingKnownManagedPath: false
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
