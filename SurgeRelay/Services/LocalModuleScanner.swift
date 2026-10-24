import Foundation

enum LocalModuleFolderScanner {
    static func folders(
        in rootDirectoryPath: String,
        excluding excludedDirectories: [URL] = [],
        including candidateFolders: [String] = []
    ) throws -> [String] {
        let trimmedPath = rootDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return [] }

        guard let root = LocalSourcePathResolver.canonicalDirectoryURL(for: trimmedPath) else { return [] }
        let excludedPaths = excludedDirectories.map {
            $0.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
        }
        guard !isExcluded(root, paths: excludedPaths) else { return [] }
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return []
        }

        var values = Set<String>()
        for case let url as URL in enumerator {
            guard !isExcluded(url, paths: excludedPaths) else {
                enumerator.skipDescendants()
                continue
            }
            guard let resourceValues = try? url.resourceValues(forKeys: resourceKeys),
                  resourceValues.isDirectory == true,
                  resourceValues.isPackage != true,
                  resourceValues.isSymbolicLink != true else {
                enumerator.skipDescendants()
                continue
            }
            guard let relativePath = LocalSourcePathResolver.relativePath(
                forSourceURL: url.absoluteString,
                rootDirectoryPath: root.path
            ) else { continue }
            let folder = ModuleOutputFolder.normalized(relativePath)
            if !folder.isEmpty { values.insert(folder) }
        }
        for candidate in candidateFolders {
            let folder = ModuleOutputFolder.normalized(candidate)
            if !folder.isEmpty,
               isUsableFolder(folder, root: root, excludedPaths: excludedPaths) {
                values.insert(folder)
            }
        }
        return values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func isUsableFolder(
        _ folder: String,
        in rootDirectoryPath: String,
        excluding excludedDirectories: [URL] = []
    ) -> Bool {
        guard let root = LocalSourcePathResolver.canonicalDirectoryURL(for: rootDirectoryPath) else { return false }
        let excludedPaths = excludedDirectories.map {
            $0.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
        }
        return isUsableFolder(folder, root: root, excludedPaths: excludedPaths)
    }

    private static func isUsableFolder(_ folder: String, root: URL, excludedPaths: [String]) -> Bool {
        let components = ModuleOutputFolder.components(folder)
        let destination = root.appending(path: components.joined(separator: "/"), directoryHint: .isDirectory)
        guard !isExcluded(destination, paths: excludedPaths),
              components.allSatisfy({ !$0.hasPrefix(".") }) else { return false }
        var directory = root
        for index in 0...components.count {
            if index > 0 { directory.append(path: components[index - 1], directoryHint: .isDirectory) }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory,
                      (try directory.resourceValues(forKeys: [.isPackageKey])).isPackage != true else { return false }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return true
            } catch {
                return false
            }
        }
        return true
    }

    private static func isExcluded(_ url: URL, paths: [String]) -> Bool {
        let path = url.standardizedFileURL.path
        return paths.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}

struct LocalModuleMetadataSnapshot: Equatable, Sendable {
    var localStorageRelativePath: String
    var scriptHubSubscription: ScriptHubSubscriptionInfo?
}

enum LocalModuleMetadataReader {
    static func snapshot(
        for module: RelayModule,
        rootDirectoryPath: String
    ) -> LocalModuleMetadataSnapshot? {
        guard module.hasLocalStorageTarget,
              let relativePath = module.localStorageRelativePath,
              let fileURL = fileURL(relativePath: relativePath, rootDirectoryPath: rootDirectoryPath),
              let data = try? Data(contentsOf: fileURL),
              !data.isEmpty,
              data.count <= 20 * 1024 * 1024,
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        guard let realRelativePath = LocalSourcePathResolver.relativePath(
            forSourceURL: fileURL.absoluteString,
            rootDirectoryPath: rootDirectoryPath
        ) else { return nil }
        return LocalModuleMetadataSnapshot(
            localStorageRelativePath: realRelativePath,
            scriptHubSubscription: ModuleMetadataParser.scriptHubSubscription(in: content)
        )
    }

    private static func fileURL(relativePath: String, rootDirectoryPath: String) -> URL? {
        let trimmedRoot = rootDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRoot.isEmpty,
              let candidate = LocalSourcePathResolver.fileURL(
                relativePath: relativePath,
                rootDirectoryPath: trimmedRoot
              ),
              candidate.pathExtension.lowercased() == "sgmodule" else {
            return nil
        }
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }

        let directory = candidate.deletingLastPathComponent()
        guard let siblings = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let expectedIdentity = fileNameIdentity(candidate.lastPathComponent)
        let matches = siblings.filter { url in
            url.pathExtension.lowercased() == "sgmodule"
                && fileNameIdentity(url.lastPathComponent) == expectedIdentity
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        guard matches.count == 1 else { return nil }
        return LocalSourcePathResolver.relativePath(
            forSourceURL: matches[0].absoluteString,
            rootDirectoryPath: trimmedRoot
        ) != nil ? matches[0].standardizedFileURL.resolvingSymlinksInPath() : nil
    }

    private static func fileNameIdentity(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }
}

struct LocalModuleScanCandidate: Identifiable, Hashable, Sendable {
    var relativePath: String
    var localStorageRelativePath: String
    var sourceURL: String
    var sourceFormat: ModuleSourceFormat
    var name: String
    var outputFileName: String
    var category: String
    var outputFolder: String
    var scriptHubOptions: ScriptHubOptions
    var scriptHubSubscription: ScriptHubSubscriptionInfo?
    var sourceContentHash: String?
    var rootDirectoryPath: String? = nil

    var id: String { relativePath }

    var initialSource: ModuleInitialSource {
        ModuleInitialSource.resolved(
            subscription: scriptHubSubscription,
            sourceURL: sourceURL,
            sourceFormat: sourceFormat
        )
    }

    var relationshipSummary: String {
        "\(ModuleStorageLocation.local.title) · \(initialSource.title)"
    }
}

struct LocalModuleScanSkippedFile: Identifiable, Hashable, Sendable {
    var relativePath: String
    var reason: String

    var id: String { "\(relativePath)-\(reason)" }
}

struct LocalModuleScanReport: Sendable {
    var candidates: [LocalModuleScanCandidate]
    var skippedFiles: [LocalModuleScanSkippedFile]
}

struct LocalModuleImportSourceSnapshot: Sendable {
    var candidate: LocalModuleScanCandidate
    var fileURL: URL
    var data: Data
}

enum LocalModuleScanner {
    static func snapshotForImport(
        _ candidate: LocalModuleScanCandidate,
        rootDirectoryPath: String
    ) throws -> LocalModuleImportSourceSnapshot {
        if let scannedRoot = candidate.rootDirectoryPath,
           LocalSourcePathResolver.canonicalDirectoryURL(for: scannedRoot) !=
            LocalSourcePathResolver.canonicalDirectoryURL(for: rootDirectoryPath) {
            throw RelayError.invalidOutput("本地模块根目录已改变，请重新扫描")
        }
        guard let fileURL = LocalSourcePathResolver.fileURL(
            relativePath: candidate.localStorageRelativePath,
            rootDirectoryPath: rootDirectoryPath
        ), fileURL.pathExtension.lowercased() == "sgmodule",
              (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let relativePath = LocalSourcePathResolver.relativePath(
                forSourceURL: fileURL.absoluteString,
                rootDirectoryPath: rootDirectoryPath
              ), LocalSourcePathResolver.pathIdentity(relativePath) ==
                LocalSourcePathResolver.pathIdentity(candidate.localStorageRelativePath) else {
            throw RelayError.invalidOutput("本地来源路径已改变，请重新扫描")
        }
        let data = try SourceRevisionService.readLocalSource(fileURL)
        guard !ManagedPublishedFile.hasManagementHeader(data) else {
            throw RelayError.invalidOutput("这是 Surge Relay 发布文件，请重新扫描")
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw RelayError.invalidOutput("来源不是有效的 UTF-8 模块文本。")
        }
        var refreshed = candidate
        let subscription = ModuleMetadataParser.scriptHubSubscription(in: content)
        refreshed.relativePath = relativePath
        refreshed.localStorageRelativePath = relativePath
        refreshed.sourceURL = subscription?.originalURL ?? fileURL.absoluteString
        refreshed.sourceFormat = subscription?.sourceFormat ?? .surge
        refreshed.scriptHubSubscription = subscription
        refreshed.scriptHubOptions = subscription?.options ?? ScriptHubOptions()
        refreshed.sourceContentHash = subscription == nil ? data.sha256String : nil
        return LocalModuleImportSourceSnapshot(candidate: refreshed, fileURL: fileURL, data: data)
    }

    static func candidates(
        in rootDirectoryPath: String,
        existingModules: [RelayModule],
        publishedFilePaths: [String]
    ) throws -> [LocalModuleScanCandidate] {
        try report(
            in: rootDirectoryPath,
            existingModules: existingModules,
            publishedFilePaths: publishedFilePaths
        ).candidates
    }

    static func report(
        in rootDirectoryPath: String,
        existingModules: [RelayModule],
        publishedFilePaths: [String]
    ) throws -> LocalModuleScanReport {
        let trimmedPath = rootDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw RelayError.invalidOutput("请先设置本地模块根目录。")
        }

        guard let root = LocalSourcePathResolver.canonicalDirectoryURL(for: trimmedPath) else {
            throw RelayError.invalidOutput("请先设置本地模块根目录。")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RelayError.invalidOutput("本地模块根目录不存在。")
        }

        var existingSources = Set(existingModules.flatMap {
            [$0.updateSourceURL, $0.sourceURL].map(ModuleSourceIdentity.canonicalValue)
        })
        var existingPaths = Set(existingModules.map { LocalSourcePathResolver.pathIdentity($0.publishedRelativePath) })
        existingPaths.formUnion(existingModules.compactMap { $0.localStorageRelativePath }.map(LocalSourcePathResolver.pathIdentity))
        existingPaths.formUnion(existingModules.compactMap {
            LocalSourcePathResolver.storageRelativePath(for: $0, rootDirectoryPath: root.path)
        }.map(LocalSourcePathResolver.pathIdentity))
        existingPaths.formUnion(publishedFilePaths.map(LocalSourcePathResolver.pathIdentity))

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return LocalModuleScanReport(candidates: [], skippedFiles: [])
        }

        var values: [LocalModuleScanCandidate] = []
        var skipped: [LocalModuleScanSkippedFile] = []
        var seenPaths = Set<String>()
        let fileURLs = enumerator.compactMap { $0 as? URL }.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        for fileURL in fileURLs {
            let standardizedURL = fileURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
            guard standardizedURL.pathExtension.lowercased() == "sgmodule",
                  (try? standardizedURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            guard let relativePath = LocalSourcePathResolver.relativePath(
                forSourceURL: standardizedURL.absoluteString,
                rootDirectoryPath: root.path
            ) else {
                skipped.append(LocalModuleScanSkippedFile(
                    relativePath: standardizedURL.lastPathComponent,
                    reason: "无法解析相对路径"
                ))
                continue
            }
            let normalizedRelativePath = relativePath
            let relativeKey = LocalSourcePathResolver.pathIdentity(relativePath)
            if existingPaths.contains(relativeKey) {
                skipped.append(LocalModuleScanSkippedFile(
                    relativePath: normalizedRelativePath,
                    reason: "发布路径已纳入管理"
                ))
                continue
            }
            guard seenPaths.insert(relativeKey).inserted else {
                skipped.append(LocalModuleScanSkippedFile(
                    relativePath: normalizedRelativePath,
                    reason: "扫描中发现重复路径"
                ))
                continue
            }

            let data: Data
            do {
                data = try Data(contentsOf: standardizedURL)
            } catch {
                skipped.append(LocalModuleScanSkippedFile(
                    relativePath: normalizedRelativePath,
                    reason: "无法读取文件：\(error.localizedDescription)"
                ))
                continue
            }
            guard !data.isEmpty else {
                skipped.append(LocalModuleScanSkippedFile(
                    relativePath: normalizedRelativePath,
                    reason: "文件为空"
                ))
                continue
            }
            guard data.count <= 20 * 1024 * 1024 else {
                skipped.append(LocalModuleScanSkippedFile(
                    relativePath: normalizedRelativePath,
                    reason: "文件超过 20 MB"
                ))
                continue
            }
            if ManagedPublishedFile.hasManagementHeader(data) {
                skipped.append(LocalModuleScanSkippedFile(
                    relativePath: normalizedRelativePath,
                    reason: "这是 Surge Relay 发布文件"
                ))
                continue
            }
            guard let content = String(data: data, encoding: .utf8) else {
                skipped.append(LocalModuleScanSkippedFile(
                    relativePath: normalizedRelativePath,
                    reason: "不是有效的 UTF-8 文本"
                ))
                continue
            }
            let subscription = ModuleMetadataParser.scriptHubSubscription(in: content)
            let sourceURL = subscription?.originalURL ?? standardizedURL.absoluteString
            let sourceKey = ModuleSourceIdentity.canonicalValue(for: sourceURL)
            guard existingSources.insert(sourceKey).inserted else {
                skipped.append(LocalModuleScanSkippedFile(
                    relativePath: normalizedRelativePath,
                    reason: "来源文件已纳入管理"
                ))
                continue
            }
            let components = normalizedRelativePath.split(separator: "/").map(String.init)
            let outputFileName = components.last ?? standardizedURL.lastPathComponent
            let outputFolder = components.dropLast().joined(separator: "/")
            let fallbackName = FilenameSanitizer.baseName(from: outputFileName)
                .replacingOccurrences(of: "-", with: " ")
            let sourceFormat = subscription?.sourceFormat ?? .surge
            let sourceContentHash = subscription == nil ? data.sha256String : nil
            values.append(LocalModuleScanCandidate(
                relativePath: normalizedRelativePath,
                localStorageRelativePath: normalizedRelativePath,
                sourceURL: sourceURL,
                sourceFormat: sourceFormat,
                name: ModuleMetadataParser.displayName(in: content) ?? fallbackName,
                outputFileName: FilenameSanitizer.existingSgmoduleName(from: outputFileName),
                category: ModuleMetadataParser.category(in: content) ?? subscription?.category ?? "",
                outputFolder: ModuleOutputFolder.normalized(outputFolder),
                scriptHubOptions: subscription?.options ?? ScriptHubOptions(),
                scriptHubSubscription: subscription,
                sourceContentHash: sourceContentHash,
                rootDirectoryPath: root.path
            ))
        }

        return LocalModuleScanReport(
            candidates: values.sorted { lhs, rhs in
                lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
            },
            skippedFiles: skipped.sorted { lhs, rhs in
                lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
            }
        )
    }
}
