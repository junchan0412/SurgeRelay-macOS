import Foundation

struct LocalModuleImportEntry: Equatable, Sendable {
    var candidate: LocalModuleScanCandidate
    var module: RelayModule
}

struct LocalModuleImportPlan: Equatable, Sendable {
    var entries: [LocalModuleImportEntry]
    var failures: [String]
}

enum LocalModuleImportPlanner {
    static let scanStartedStatus = "正在扫描本地模块根目录…"
    static let scanFailedStatus = "本地模块扫描失败"
    static let noSelectionStatus = "没有选择需要导入的本地模块"
    static let emptyImportStatus = "本地模块扫描完成，但没有可导入项目"

    static func plan(
        candidates: [LocalModuleScanCandidate],
        existingModules: [RelayModule],
        localModuleDirectory: String? = nil,
        plannedAt: Date = .now
    ) -> LocalModuleImportPlan {
        var entries: [LocalModuleImportEntry] = []
        var failures: [String] = []
        var unavailablePaths = Set(existingModules.flatMap {
            [$0.publishedRelativePath] + [$0.localStorageRelativePath].compactMap { $0 }
        }.map(LocalSourcePathResolver.pathIdentity))
        if let localModuleDirectory {
            unavailablePaths.formUnion(existingModules.compactMap {
                LocalSourcePathResolver.storageRelativePath(for: $0, rootDirectoryPath: localModuleDirectory)
            }.map(LocalSourcePathResolver.pathIdentity))
        }
        var unavailableSources = Set(existingModules.flatMap {
            [$0.updateSourceURL, $0.sourceURL].map(ModuleSourceIdentity.canonicalValue)
        })

        for candidate in candidates {
            let name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                failures.append("\(candidate.relativePath)：模块名称不能为空")
                continue
            }

            if let scannedRoot = candidate.rootDirectoryPath,
               let localModuleDirectory,
               LocalSourcePathResolver.canonicalDirectoryURL(for: scannedRoot) !=
                LocalSourcePathResolver.canonicalDirectoryURL(for: localModuleDirectory) {
                failures.append("\(candidate.relativePath)：本地模块根目录已改变，请重新扫描")
                continue
            }
            let components = candidate.localStorageRelativePath
                .replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  let fileName = components.last,
                  fileName.lowercased().hasSuffix(".sgmodule") else {
                failures.append("\(candidate.relativePath)：本地模块路径无效")
                continue
            }
            let outputFolder = components.dropLast().joined(separator: "/")
            let outputFileName = String(fileName)
            let outputPath = ModuleOutputFolder.relativePath(
                fileName: outputFileName,
                folder: outputFolder,
                preservesExistingFileName: true
            )
            let pathKey = LocalSourcePathResolver.pathIdentity(candidate.localStorageRelativePath)
            guard LocalSourcePathResolver.pathIdentity(outputPath) == pathKey else {
                failures.append("\(candidate.relativePath)：文件名无法保留，请先调整本地文件名后重新扫描")
                continue
            }
            let source = candidate.scriptHubSubscription?.originalURL ?? candidate.sourceURL
            guard let sourceURL = URL(string: source),
                  sourceURL.isFileURL || (["http", "https"].contains(sourceURL.scheme?.lowercased()) && sourceURL.host?.isEmpty == false) else {
                failures.append("\(candidate.relativePath)：来源地址无效")
                continue
            }
            if sourceURL.isFileURL, let localModuleDirectory {
                guard let sourcePath = LocalSourcePathResolver.relativePath(
                    forSourceURL: source,
                    rootDirectoryPath: localModuleDirectory
                ), LocalSourcePathResolver.pathIdentity(sourcePath) == pathKey else {
                    failures.append("\(candidate.relativePath)：本地来源路径已改变，请重新扫描")
                    continue
                }
            }
            guard !unavailablePaths.contains(pathKey) else {
                failures.append("\(candidate.relativePath)：本地模块路径已纳入管理或与其他模块冲突，请重新扫描")
                continue
            }
            let sourceKey = ModuleSourceIdentity.canonicalValue(for: source)
            guard !unavailableSources.contains(sourceKey) else {
                failures.append("\(candidate.relativePath)：来源文件已纳入管理，请重新扫描")
                continue
            }
            unavailablePaths.insert(pathKey)
            unavailableSources.insert(sourceKey)

            let module = RelayModule(
                name: name,
                sourceURL: source,
                sourceFormat: candidate.sourceFormat,
                outputFileName: outputFileName,
                category: candidate.category,
                outputFolder: outputFolder,
                storageLocation: .local,
                localStorageRelativePath: outputPath,
                preservesOutputFileName: true,
                scriptHubOptions: candidate.scriptHubOptions,
                scriptHubSubscription: candidate.scriptHubSubscription,
                detectedSourceFormat: candidate.sourceFormat == .automatic ? nil : candidate.sourceFormat,
                createdAt: plannedAt,
                sourceContentHash: candidate.sourceContentHash,
                sourceCheckedAt: plannedAt
            )
            entries.append(LocalModuleImportEntry(candidate: candidate, module: module))
        }

        return LocalModuleImportPlan(entries: entries, failures: failures)
    }

    static func scanStatus(for report: LocalModuleScanReport) -> String {
        if report.candidates.isEmpty {
            return report.skippedFiles.isEmpty
                ? "未发现可导入的新本地模块"
                : "未发现可导入的新本地模块；已跳过 \(report.skippedFiles.count) 个文件"
        }
        let skippedSuffix = report.skippedFiles.isEmpty ? "" : "，跳过 \(report.skippedFiles.count) 个文件"
        return "发现 \(report.candidates.count) 个可导入本地模块\(skippedSuffix)"
    }

    static func importStatus(importedCount: Int, failureCount: Int) -> String {
        let failureSuffix = failureCount == 0 ? "" : "；\(failureCount) 个文件无法导入"
        return "已导入 \(importedCount) 个本地模块\(failureSuffix)"
    }

    static func successfulImportModule(
        _ module: RelayModule,
        convertedContent: String,
        contentHash: String,
        importedAt: Date = .now
    ) -> RelayModule {
        var module = module
        if let subscription = ModuleMetadataParser.scriptHubSubscription(in: convertedContent) {
            _ = module.reconcileScriptHubSubscriptionMetadata(subscription)
        } else if module.scriptHubSubscription == nil,
                  let embedded = ModuleMetadataParser.scriptHubSubscription(from: module.sourceURL) {
            module.scriptHubSubscription = embedded
        }
        _ = module.repairSourceFormatFromUpdateSource()
        module.detectedSourceFormat = ModuleNamingPlanner.detectedFormat(
            for: module.sourceFormat,
            source: module.updateSourceURL
        )
        module.contentHash = contentHash
        module.lastUpdatedAt = importedAt
        module.state = .current
        module.lastError = nil
        return module
    }

    static func failureDetails(_ failures: [String], isPartialImport: Bool) -> String? {
        guard !failures.isEmpty else { return nil }
        let title = isPartialImport ? "部分本地模块无法导入" : "以下本地模块无法导入"
        return "\(title)：\n\(failures.joined(separator: "\n"))"
    }
}
