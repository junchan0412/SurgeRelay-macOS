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
}
