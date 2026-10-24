import Foundation

enum ModuleNamingPlanner {
    /// 为“复制模块”生成不冲突的副本名称：`名称 副本`、`名称 副本 2`…
    static func duplicateName(base: String, existing: [String]) -> String {
        let baseName = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingSet = Set(existing)
        let candidate = "\(baseName) 副本"
        guard existingSet.contains(candidate) else { return candidate }
        var suffix = 2
        while existingSet.contains("\(baseName) 副本 \(suffix)") { suffix += 1 }
        return "\(baseName) 副本 \(suffix)"
    }

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
        // detectedSourceFormat is only meaningful for automatic recognition UI.
        // Explicit mislabels are repaired into sourceFormat itself.
        guard format == .automatic, let url = URL(string: source) else { return nil }
        return format.resolvedFormat(for: url)
    }

    static func uniqueOutputFileName(
        for draft: ModuleDraft,
        source: String,
        modules: [RelayModule],
        excluding excludedID: UUID? = nil
    ) -> String {
        let preservesExistingFileName = URL(string: source)?.isFileURL == true
        let normalized = draft.normalizedOutputFileName(for: source)
        let folder = ModuleOutputFolder.normalized(draft.outputFolder)
        let unavailable = Set(modules.filter { $0.id != excludedID }.flatMap { module in
            [module.publishedRelativePath] + [module.localStorageRelativePath].compactMap { $0 }
        }.map(LocalSourcePathResolver.pathIdentity))
        let relativePath = ModuleOutputFolder.relativePath(
            fileName: normalized,
            folder: folder,
            preservesExistingFileName: draft.storageLocation == .local || preservesExistingFileName
        )
        guard unavailable.contains(LocalSourcePathResolver.pathIdentity(relativePath)) else { return normalized }

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
        let unavailable = Set(unavailable.map(LocalSourcePathResolver.pathIdentity))
        let normalized = preservesExistingFileName
            ? FilenameSanitizer.existingSgmoduleName(from: preferredFileName)
            : FilenameSanitizer.sgmoduleName(from: preferredFileName)
        var relativePath = ModuleOutputFolder.relativePath(
            fileName: normalized,
            folder: folder,
            preservesExistingFileName: preservesExistingFileName
        )
        guard unavailable.contains(LocalSourcePathResolver.pathIdentity(relativePath)) else { return normalized }

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
            if unavailable.contains(LocalSourcePathResolver.pathIdentity(relativePath)) {
                suffix += 1
            } else {
                break
            }
        } while true
        return "\(base)-\(suffix).sgmodule"
    }

    static func normalizedModuleNaming(
        _ modules: [RelayModule],
        localModuleDirectory: String
    ) -> [RelayModule] {
        let normalizedModules = modules.map { value in
            var module = value
            module.outputFolder = ModuleOutputFolder.normalized(module.outputFolder)
            if module.hasLocalStorageTarget {
                let hadLocalPath = module.localStorageRelativePath != nil
                if module.localStorageRelativePath == nil {
                    module.localStorageRelativePath = LocalSourcePathResolver.relativePath(
                        forSourceURL: module.sourceURL,
                        rootDirectoryPath: localModuleDirectory
                    ) ?? module.publishedRelativePath
                }
                module.preservesOutputFileName = true
                let currentOutputPath = module.publishedRelativePath
                let localSourcePath = LocalSourcePathResolver.relativePath(
                    forSourceURL: module.sourceURL,
                    rootDirectoryPath: localModuleDirectory
                )
                let localPath = module.localStorageRelativePath
                let shouldRestorePhysicalPath = localPath.map {
                    !hadLocalPath || localSourcePath == nil ||
                        LocalSourcePathResolver.pathIdentity(currentOutputPath) == LocalSourcePathResolver.pathIdentity($0)
                } ?? false
                if shouldRestorePhysicalPath,
                   let components = localPath?.split(separator: "/"),
                   let fileName = components.last {
                    module.outputFileName = FilenameSanitizer.existingSgmoduleName(from: String(fileName))
                    module.outputFolder = components.dropLast().joined(separator: "/")
                }
            }
            return module
        }
        var used = Set(normalizedModules.filter(\.hasLocalStorageTarget).flatMap {
            [$0.publishedRelativePath] + [$0.localStorageRelativePath].compactMap { $0 }
        }.map(LocalSourcePathResolver.pathIdentity))
        return normalizedModules.map { value in
            var module = value
            guard !module.hasLocalStorageTarget else { return module }
            let preservesExistingFileName = module.preservesOutputFileName ||
                URL(string: module.sourceURL)?.isFileURL == true
            let preferredValue = module.outputFileName.isEmpty ? module.name : module.outputFileName
            let preferred = preservesExistingFileName
                ? FilenameSanitizer.existingSgmoduleName(from: preferredValue)
                : FilenameSanitizer.sgmoduleName(from: preferredValue)
            let candidate = uniqueOutputFileName(
                preferredFileName: preferred,
                folder: module.outputFolder,
                unavailable: used,
                preservesExistingFileName: preservesExistingFileName
            )
            module.outputFileName = candidate
            used.insert(LocalSourcePathResolver.pathIdentity(module.publishedRelativePath))
            return module
        }
    }
}
