import Foundation

enum LocalModuleFolderScanner {
    static func folders(in rootDirectoryPath: String) throws -> [String] {
        let trimmedPath = rootDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return [] }

        let root = URL(filePath: trimmedPath, directoryHint: .isDirectory).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return []
        }

        var values = Set<String>()
        for case let url as URL in enumerator {
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard resourceValues.isDirectory == true, resourceValues.isPackage != true else { continue }
            guard let relativePath = relativePath(for: url.standardizedFileURL, root: root) else { continue }
            let folder = ModuleOutputFolder.normalized(relativePath)
            if !folder.isEmpty { values.insert(folder) }
        }
        return values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func relativePath(for fileURL: URL, root: URL) -> String? {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard fileURL.path.hasPrefix(rootPath) else { return nil }
        return String(fileURL.path.dropFirst(rootPath.count))
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
        guard module.storageLocation == .local,
              let relativePath = module.localStorageRelativePath,
              let fileURL = fileURL(relativePath: relativePath, rootDirectoryPath: rootDirectoryPath),
              let data = try? Data(contentsOf: fileURL),
              !data.isEmpty,
              data.count <= 20 * 1024 * 1024,
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        let root = URL(filePath: rootDirectoryPath, directoryHint: .isDirectory).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard fileURL.path.hasPrefix(rootPrefix) else { return nil }
        return LocalModuleMetadataSnapshot(
            localStorageRelativePath: String(fileURL.path.dropFirst(rootPrefix.count)),
            scriptHubSubscription: ModuleMetadataParser.scriptHubSubscription(in: content)
        )
    }

    private static func fileURL(relativePath: String, rootDirectoryPath: String) -> URL? {
        let trimmedRoot = rootDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRelativePath = ModuleOutputFolder.normalized(relativePath)
        guard !trimmedRoot.isEmpty, !normalizedRelativePath.isEmpty else { return nil }

        let root = URL(filePath: trimmedRoot, directoryHint: .isDirectory).standardizedFileURL
        let candidate = root.appending(path: normalizedRelativePath).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix),
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
        return matches.count == 1 ? matches[0].standardizedFileURL : nil
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

    var id: String { relativePath }

    var initialSource: ModuleInitialSource {
        guard let scriptHubSubscription else { return .selfAuthored }
        guard let url = URL(string: scriptHubSubscription.originalURL),
              ["http", "https"].contains(url.scheme?.lowercased()) else {
            return .invalid
        }
        return .subscribed(scriptHubSubscription.sourceFormat ?? sourceFormat.resolvedFormat(for: url))
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

enum LocalModuleScanner {
    static func candidates(
        in rootDirectoryPath: String,
        combinedFileName: String,
        existingModules: [RelayModule],
        publishedFilePaths: [String]
    ) throws -> [LocalModuleScanCandidate] {
        try report(
            in: rootDirectoryPath,
            combinedFileName: combinedFileName,
            existingModules: existingModules,
            publishedFilePaths: publishedFilePaths
        ).candidates
    }

    static func report(
        in rootDirectoryPath: String,
        combinedFileName: String,
        existingModules: [RelayModule],
        publishedFilePaths: [String]
    ) throws -> LocalModuleScanReport {
        let trimmedPath = rootDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw RelayError.invalidOutput("请先设置本地模块根目录。")
        }

        let root = URL(filePath: trimmedPath, directoryHint: .isDirectory).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RelayError.invalidOutput("本地模块根目录不存在。")
        }

        let combined = ModuleOutputFolder.relativePath(
            fileName: combinedFileName,
            folder: ModuleOutputFolder.root
        ).lowercased()
        var existingSources = Set(existingModules.map { ModuleSourceIdentity.canonicalValue(for: $0.updateSourceURL) })
        var existingPaths = Set(existingModules.map { $0.publishedRelativePath.lowercased() })
        existingPaths.formUnion(existingModules.compactMap { $0.localStorageRelativePath?.lowercased() })
        existingPaths.formUnion(publishedFilePaths.map { ModuleOutputFolder.normalized($0).lowercased() })
        existingPaths.insert(combined)

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
        for case let fileURL as URL in enumerator {
            let standardizedURL = fileURL.standardizedFileURL
            guard standardizedURL.pathExtension.lowercased() == "sgmodule",
                  (try? standardizedURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            guard let relativePath = relativePath(for: standardizedURL, root: root) else {
                skipped.append(LocalModuleScanSkippedFile(
                    relativePath: standardizedURL.lastPathComponent,
                    reason: "无法解析相对路径"
                ))
                continue
            }
            let normalizedRelativePath = normalizeRelativePath(relativePath)
            let relativeKey = normalizedRelativePath.lowercased()
            if relativeKey == combined {
                skipped.append(LocalModuleScanSkippedFile(
                    relativePath: normalizedRelativePath,
                    reason: "这是当前总模块文件"
                ))
                continue
            }
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
                sourceContentHash: sourceContentHash
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

    private static func relativePath(for fileURL: URL, root: URL) -> String? {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard fileURL.path.hasPrefix(rootPath) else { return nil }
        return String(fileURL.path.dropFirst(rootPath.count))
    }

    private static func normalizeRelativePath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }
}
