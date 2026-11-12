import Foundation

@MainActor
extension AppModel {
    func scanExistingLocalModules(reportsProgress: Bool = true) async throws -> LocalModuleScanReport {
        guard !isWorking else {
            throw RelayError.invalidOutput(updateAdmission.message)
        }
        if reportsProgress {
            beginWork(.scanningLocalModules)
            statusMessage = LocalModuleImportPlanner.scanStartedStatus
        }
        defer { if reportsProgress { endWork(.scanningLocalModules) } }
        let configured = ModuleOutputFormat.allCases.filter { settings.localStorage(for: $0).isEnabled && !settings.localModuleDirectory(for: $0).isEmpty }
        guard !configured.isEmpty else { throw RelayError.invalidOutput("请先启用并设置客户端的本地存储目录。") }
        var candidates: [LocalModuleScanCandidate] = []
        var skipped: [LocalModuleScanSkippedFile] = []
        let originalSettings = settings
        for format in configured {
            let rootDirectoryPath = settings.localModuleDirectory(for: format)
            let existingModules = localModulesSharingRoot(rootDirectoryPath)
            let storage = settings.localStorage(for: format)
            var publishedFilePaths = LocalSourcePathResolver.canonicalDirectoryURL(for: storage.publishedRootDirectory ?? "")
                == LocalSourcePathResolver.canonicalDirectoryURL(for: rootDirectoryPath) ? storage.publishedFilePaths : []
            publishedFilePaths.append(contentsOf: registeredLocalModuleFiles.compactMap {
                LocalSourcePathResolver.relativePath(forSourceURL: $0.absoluteString, rootDirectoryPath: rootDirectoryPath)
            })
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try LocalModuleScanner.report(in: rootDirectoryPath, existingModules: existingModules,
                        publishedFilePaths: publishedFilePaths, outputFormat: format)
                }.value
                for candidate in report.candidates {
                    let fileURL = LocalSourcePathResolver.fileURL(relativePath: candidate.localStorageRelativePath,
                        rootDirectoryPath: rootDirectoryPath)
                    if let index = candidates.firstIndex(where: {
                        LocalSourcePathResolver.fileURL(relativePath: $0.localStorageRelativePath,
                            rootDirectoryPath: $0.rootDirectoryPath ?? "") == fileURL
                    }) {
                        if candidate.scriptHubSubscription?.target == candidate.outputFormat.scriptHubTarget,
                           candidates[index].scriptHubSubscription?.target != candidates[index].outputFormat.scriptHubTarget {
                            candidates[index] = candidate
                        }
                    } else {
                        candidates.append(candidate)
                    }
                }
                skipped.append(contentsOf: report.skippedFiles.map { file in
                    LocalModuleScanSkippedFile(relativePath: format.title + " · " + file.relativePath, reason: file.reason)
                })
            } catch {
                skipped.append(LocalModuleScanSkippedFile(relativePath: format.title + " 目录", reason: error.localizedDescription))
            }
            guard settings == originalSettings, !Task.isCancelled, workspaceIsActive, !isWorkspaceTransitioning,
                  reportsProgress || !isWorking else {
                throw CancellationError()
            }
        }
        let report = LocalModuleScanReport(candidates: candidates, skippedFiles: skipped)
        if reportsProgress { statusMessage = LocalModuleImportPlanner.scanStatus(for: report) }
        return report
    }

    func importLocalModules(_ candidates: [LocalModuleScanCandidate]) async {
        guard !isWorking else { return }
        guard !candidates.isEmpty else {
            statusMessage = LocalModuleImportPlanner.noSelectionStatus
            return
        }
        beginWork(.importingLocalModules)
        defer { endWork(.importingLocalModules) }

        registerLocalChange()
        presentedError = nil
        statusMessage = "正在从本地文件导入模块…"
        var imported: [RelayModule] = []
        var failures: [String] = []

        for candidate in candidates {
            guard shouldContinueCurrentWork() else { return }
            do {
                let format = candidate.outputFormat
                guard settings.localStorage(for: format).isEnabled else { throw RelayError.invalidOutput("\(format.title) 本地存储已关闭。") }
                let rootDirectoryPath = settings.localModuleDirectory(for: format)
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try LocalModuleScanner.snapshotForImport(candidate, rootDirectoryPath: rootDirectoryPath, outputFormat: format)
                }.value
                guard shouldContinueCurrentWork() else { return }
                guard !registeredLocalModuleFiles.contains(snapshot.fileURL) else {
                    throw RelayError.invalidOutput("本地模块路径已纳入管理，请重新扫描")
                }
                let importPlan = LocalModuleImportPlanner.plan(
                    candidates: [snapshot.candidate],
                    existingModules: localModulesSharingRoot(rootDirectoryPath) + imported.filter {
                        LocalSourcePathResolver.canonicalDirectoryURL(for: settings.localModuleDirectory(for: $0.outputFormat))
                            == LocalSourcePathResolver.canonicalDirectoryURL(for: rootDirectoryPath)
                    },

                    localModuleDirectory: rootDirectoryPath
                )
                failures.append(contentsOf: importPlan.failures)
                guard let entry = importPlan.entries.first else { continue }
                let module = entry.module
                let namedContent = await processingWorker.applyingModuleMetadata(
                    name: module.name, category: module.category, desc: module.moduleDescription,
                    iconURL: module.customIconURL, to: snapshot.content, outputFormat: module.outputFormat
                )
                let subscribedContent = ModuleMetadataParser.applyingScriptHubSubscription(module.scriptHubSubscription, to: namedContent)
                try await scriptHubClient.validate(subscribedContent, outputFormat: module.outputFormat)
                let result = ConversionResult(content: subscribedContent, requestURL: snapshot.fileURL, outputFormat: module.outputFormat)
                guard settings.localStorage(for: format).isEnabled, settings.localModuleDirectory(for: format) == rootDirectoryPath,
                      shouldContinueCurrentWork() else { return }
                try await fileStore.commitConversion(result, id: module.id)
                let fingerprint = await processingWorker.contentFingerprint(
                    of: result.content,
                    assets: result.assets
                )
                imported.append(LocalModuleImportPlanner.successfulImportModule(
                    module,
                    convertedContent: result.content,
                    contentHash: fingerprint
                ))
            } catch {
                guard shouldContinueCurrentWork() else { return }
                failures.append("\(candidate.relativePath)：\(error.localizedDescription)")
            }
        }

        guard shouldContinueCurrentWork() else { return }

        guard !imported.isEmpty else {
            statusMessage = LocalModuleImportPlanner.emptyImportStatus
            if let failureDetails = LocalModuleImportPlanner.failureDetails(failures, isPartialImport: false) {
                presentedError = failureDetails
            }
            return
        }

        modules.append(contentsOf: imported)
        selectedModuleID = imported.first?.id
        do {
            try persistModules()
            try await flushPersistence()
        } catch {
            presentedError = "保存导入模块失败：\(error.localizedDescription)"
            statusMessage = "模块已导入内存，但尚未保存到磁盘"
            return
        }
        refreshLocalSourceWatching()
        statusMessage = LocalModuleImportPlanner.importStatus(importedCount: imported.count, failureCount: failures.count)
        if let failureDetails = LocalModuleImportPlanner.failureDetails(failures, isPartialImport: true) {
            presentedError = failureDetails
        }
    }
    private var registeredLocalModuleFiles: Set<URL> {
        Set(modules.filter(\.hasLocalStorageTarget).compactMap { module in
            LocalSourcePathResolver.fileURL(relativePath: module.localStorageRelativePath ?? module.publishedRelativePath,
                rootDirectoryPath: settings.localModuleDirectory(for: module.outputFormat))
        })
    }

    private func localModulesSharingRoot(_ target: String) -> [RelayModule] {
        let root = LocalSourcePathResolver.canonicalDirectoryURL(for: target)
        return modules.filter { module in
            LocalSourcePathResolver.canonicalDirectoryURL(for: settings.localModuleDirectory(for: module.outputFormat)) == root ||
                LocalSourcePathResolver.storageRelativePath(for: module, rootDirectoryPath: target) != nil
        }
    }

}
