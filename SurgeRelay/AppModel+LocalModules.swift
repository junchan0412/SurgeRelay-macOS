import Foundation

@MainActor
extension AppModel {
    func scanExistingLocalModules() async throws -> LocalModuleScanReport {
        guard !isWorking else {
            throw RelayError.invalidOutput(updateAdmission.message)
        }
        beginWork(.scanningLocalModules)
        defer { endWork(.scanningLocalModules) }
        statusMessage = LocalModuleImportPlanner.scanStartedStatus
        let rootDirectoryPath = settings.localModuleDirectory
        let existingModules = modules
        let publishedFilePaths = LocalSourcePathResolver.canonicalDirectoryURL(for: settings.localPublishedRootDirectory ?? "") ==
            LocalSourcePathResolver.canonicalDirectoryURL(for: rootDirectoryPath)
            ? settings.localPublishedFilePaths : []
        let report = try await Task.detached(priority: .userInitiated) {
            try LocalModuleScanner.report(
                in: rootDirectoryPath,
                existingModules: existingModules,
                publishedFilePaths: publishedFilePaths
            )
        }.value
        guard shouldContinueCurrentWork() else {
            return LocalModuleScanReport(candidates: [], skippedFiles: [])
        }
        statusMessage = LocalModuleImportPlanner.scanStatus(for: report)
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
        let rootDirectoryPath = settings.localModuleDirectory
        var imported: [RelayModule] = []
        var failures: [String] = []

        for candidate in candidates {
            guard shouldContinueCurrentWork() else { return }
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try LocalModuleScanner.snapshotForImport(candidate, rootDirectoryPath: rootDirectoryPath)
                }.value
                guard shouldContinueCurrentWork() else { return }
                let importPlan = LocalModuleImportPlanner.plan(
                    candidates: [snapshot.candidate],
                    existingModules: modules + imported,

                    localModuleDirectory: rootDirectoryPath
                )
                failures.append(contentsOf: importPlan.failures)
                guard let entry = importPlan.entries.first else { continue }
                let module = entry.module
                var nativeModule = module
                nativeModule.sourceURL = snapshot.fileURL.absoluteString
                nativeModule.sourceFormat = .surge
                nativeModule.scriptHubSubscription = nil
                let result = try await scriptHubClient.convert(
                    module: nativeModule,
                    sourceData: snapshot.data
                )
                guard shouldContinueCurrentWork() else { return }
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
}
