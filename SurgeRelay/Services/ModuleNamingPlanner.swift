import Foundation

enum ModuleNamingPlanner {
    static func localStorageRelativePath(
        storageLocation: ModuleStorageLocation,
        source: String,
        outputFileName: String,
        outputFolder: String,
        localModuleDirectory: String
    ) throws -> String? {
        guard storageLocation == .local else { return nil }
        let rootPath = localModuleDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootPath.isEmpty else {
            throw RelayError.invalidOutput("请先设置本地模块根目录，或将模块存放位置改为 GitHub。")
        }
        if let relativePath = LocalSourcePathResolver.relativePath(
            forSourceURL: source,
            rootDirectoryPath: rootPath
        ) {
            return relativePath
        }
        return ModuleOutputFolder.relativePath(
            fileName: outputFileName,
            folder: outputFolder,
            preservesExistingFileName: true
        )
    }

    static func detectedFormat(for format: ModuleSourceFormat, source: String) -> ModuleSourceFormat? {
        guard format == .automatic, let url = URL(string: source) else { return nil }
        return format.resolvedFormat(for: url)
    }

    static func uniqueOutputFileName(
        for draft: ModuleDraft,
        source: String,
        modules: [RelayModule],
        combinedModuleFileName: String,
        excluding excludedID: UUID? = nil
    ) -> String {
        let preservesExistingFileName = URL(string: source)?.isFileURL == true
        let normalized = draft.normalizedOutputFileName(for: source)
        let folder = ModuleOutputFolder.normalized(draft.outputFolder)
        let combined = ModuleOutputFolder.relativePath(
            fileName: combinedModuleFileName,
            folder: ModuleOutputFolder.root
        ).lowercased()
        let unavailable = Set(modules.compactMap { module -> String? in
            module.id == excludedID ? nil : module.publishedRelativePath.lowercased()
        } + [combined])
        let relativePath = ModuleOutputFolder.relativePath(
            fileName: normalized,
            folder: folder,
            preservesExistingFileName: draft.storageLocation == .local || preservesExistingFileName
        )
        guard unavailable.contains(relativePath.lowercased()) else { return normalized }

        return uniqueOutputFileName(
            preferredFileName: normalized,
            folder: folder,
            unavailable: unavailable,
            preservesExistingFileName: draft.storageLocation == .local || preservesExistingFileName
        )
    }

    static func uniqueOutputFileName(
        preferredFileName: String,
        folder: String,
        unavailable: Set<String>,
        preservesExistingFileName: Bool = false
    ) -> String {
        let normalized = preservesExistingFileName
            ? FilenameSanitizer.existingSgmoduleName(from: preferredFileName)
            : FilenameSanitizer.sgmoduleName(from: preferredFileName)
        var relativePath = ModuleOutputFolder.relativePath(
            fileName: normalized,
            folder: folder,
            preservesExistingFileName: preservesExistingFileName
        )
        guard unavailable.contains(relativePath.lowercased()) else { return normalized }

        let base = preservesExistingFileName
            ? FilenameSanitizer.existingFileBaseName(from: normalized)
            : FilenameSanitizer.baseName(from: normalized)
        var suffix = 2
        repeat {
            relativePath = ModuleOutputFolder.relativePath(
                fileName: "\(base)-\(suffix).sgmodule",
                folder: folder,
                preservesExistingFileName: preservesExistingFileName
            )
            if unavailable.contains(relativePath.lowercased()) {
                suffix += 1
            } else {
                break
            }
        } while true
        return "\(base)-\(suffix).sgmodule"
    }

    static func normalizedModuleNaming(
        _ modules: [RelayModule],
        combinedFileName: String,
        localModuleDirectory: String
    ) -> [RelayModule] {
        var used = Set<String>()
        let combined = ModuleOutputFolder.relativePath(
            fileName: combinedFileName,
            folder: ModuleOutputFolder.root
        ).lowercased()
        return modules.map { value in
            var module = value
            module.outputFolder = ModuleOutputFolder.normalized(module.outputFolder)
            if module.storageLocation == .local {
                if module.localStorageRelativePath == nil {
                    module.localStorageRelativePath = LocalSourcePathResolver.relativePath(
                        forSourceURL: module.sourceURL,
                        rootDirectoryPath: localModuleDirectory
                    ) ?? module.publishedRelativePath
                }
                module.preservesOutputFileName = true
            }
            let localSourceFileName = LocalSourcePathResolver.fileName(
                forSourceURL: module.sourceURL,
                rootDirectoryPath: localModuleDirectory
            )
            let preservesExistingFileName = module.preservesOutputFileName ||
                URL(string: module.sourceURL)?.isFileURL == true
            let preferredValue = localSourceFileName
                ?? (module.outputFileName.isEmpty ? module.name : module.outputFileName)
            let preferred = preservesExistingFileName
                ? FilenameSanitizer.existingSgmoduleName(from: preferredValue)
                : FilenameSanitizer.sgmoduleName(from: preferredValue)
            let base = preservesExistingFileName
                ? FilenameSanitizer.existingFileBaseName(from: preferred)
                : FilenameSanitizer.baseName(from: preferred)
            var candidate = preferred
            var suffix = 2
            var relative = ModuleOutputFolder.relativePath(
                fileName: candidate,
                folder: module.outputFolder,
                preservesExistingFileName: preservesExistingFileName
            )
            while used.contains(relative.lowercased()) || relative.lowercased() == combined {
                candidate = "\(base)-\(suffix).sgmodule"
                relative = ModuleOutputFolder.relativePath(
                    fileName: candidate,
                    folder: module.outputFolder,
                    preservesExistingFileName: preservesExistingFileName
                )
                suffix += 1
            }
            used.insert(relative.lowercased())
            module.outputFileName = candidate
            return module
        }
    }
}
