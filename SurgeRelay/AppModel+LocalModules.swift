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
        let combinedFileName = settings.combinedModuleFileName
        let existingModules = modules
        let publishedFilePaths = settings.localPublishedFilePaths
        let report = try await Task.detached(priority: .userInitiated) {
            try LocalModuleScanner.report(
                in: rootDirectoryPath,
                combinedFileName: combinedFileName,
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
        let importPlan = LocalModuleImportPlanner.plan(
            candidates: candidates,
            existingModules: modules,
            combinedModuleFileName: settings.combinedModuleFileName
        )
        var imported: [RelayModule] = []
        var failures = importPlan.failures

        for entry in importPlan.entries {
            guard shouldContinueCurrentWork() else { return }
            let module = entry.module
            do {
                let result = try await scriptHubClient.convert(
                    module: module,
                    github: settings.github.isConfigured ? settings.github : nil
                )
                try await fileStore.writeComponent(result.content, id: module.id)
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
                failures.append("\(entry.candidate.relativePath)：\(error.localizedDescription)")
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
        } catch {
            presentedError = "保存导入模块失败：\(error.localizedDescription)"
        }
        await rebuildCombinedFromCache()
        statusMessage = LocalModuleImportPlanner.importStatus(
            importedCount: imported.count,
            failureCount: failures.count
        )
        if let failureDetails = LocalModuleImportPlanner.failureDetails(failures, isPartialImport: true) {
            presentedError = failureDetails
        }
    }
}
