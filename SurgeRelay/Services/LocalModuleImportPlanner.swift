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
        combinedModuleFileName: String,
        plannedAt: Date = .now
    ) -> LocalModuleImportPlan {
        var entries: [LocalModuleImportEntry] = []
        var failures: [String] = []
        var unavailablePaths = Set(existingModules.map { $0.publishedRelativePath.lowercased() })
        let combinedPath = ModuleOutputFolder.relativePath(
            fileName: combinedModuleFileName,
            folder: ModuleOutputFolder.root
        ).lowercased()
        unavailablePaths.insert(combinedPath)

        for candidate in candidates {
            let name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                failures.append("\(candidate.relativePath)：模块名称不能为空")
                continue
            }

            let outputFolder = ModuleOutputFolder.normalized(candidate.outputFolder)
            let outputFileName = ModuleNamingPlanner.uniqueOutputFileName(
                preferredFileName: candidate.outputFileName,
                folder: outputFolder,
                unavailable: unavailablePaths,
                preservesExistingFileName: true
            )
            unavailablePaths.insert(
                ModuleOutputFolder.relativePath(
                    fileName: outputFileName,
                    folder: outputFolder,
                    preservesExistingFileName: true
                ).lowercased()
            )

            let module = RelayModule(
                name: name,
                sourceURL: candidate.sourceURL,
                sourceFormat: candidate.sourceFormat,
                outputFileName: outputFileName,
                category: candidate.category,
                outputFolder: outputFolder,
                storageLocation: .local,
                localStorageRelativePath: candidate.localStorageRelativePath,
                preservesOutputFileName: true,
                isEnabled: false,
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
        }
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
