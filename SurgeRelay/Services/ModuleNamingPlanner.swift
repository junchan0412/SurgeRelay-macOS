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
        localModuleDirectory: String,
        outputFormat: ModuleOutputFormat = .surge
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
            preservesExistingFileName: true,
            outputFormat: outputFormat
        )
    }

    static func detectedFormat(for format: ModuleSourceFormat, source: String) -> ModuleSourceFormat? {
        // detectedSourceFormat is only meaningful for automatic recognition UI.
        // Explicit mislabels are repaired into sourceFormat itself.
        guard format == .automatic, let url = URL(string: source) else { return nil }
        return ModuleSourceFormat.inferredFormat(for: url)
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
            preservesExistingFileName: draft.storageLocation == .local || preservesExistingFileName,
            outputFormat: draft.outputFormat
        )
        guard unavailable.contains(LocalSourcePathResolver.pathIdentity(relativePath)) else { return normalized }

        return uniqueOutputFileName(
            preferredFileName: normalized,
            folder: folder,
            unavailable: unavailable,
            preservesExistingFileName: draft.storageLocation == .local || preservesExistingFileName,
            outputFormat: draft.outputFormat
        )
    }

    static func uniqueOutputFileName(
        preferredFileName: String,
        folder: String,
        unavailable: Set<String>,
        preservesExistingFileName: Bool = false,
        outputFormat: ModuleOutputFormat = .surge
    ) -> String {
        let unavailable = Set(unavailable.map(LocalSourcePathResolver.pathIdentity))
        let normalized = FilenameSanitizer.outputFileName(from: preferredFileName, format: outputFormat,
            preservesExistingFileName: preservesExistingFileName)
        var relativePath = ModuleOutputFolder.relativePath(
            fileName: normalized,
            folder: folder,
            preservesExistingFileName: preservesExistingFileName,
            outputFormat: outputFormat
        )
        guard unavailable.contains(LocalSourcePathResolver.pathIdentity(relativePath)) else { return normalized }

        let stem = (normalized as NSString).deletingPathExtension
        let fileExtension = (normalized as NSString).pathExtension
        let base = preservesExistingFileName
            ? FilenameSanitizer.existingFileBaseName(from: stem)
            : FilenameSanitizer.baseName(from: stem)
        var suffix = 2
        repeat {
            relativePath = ModuleOutputFolder.relativePath(
                fileName: "\(base)-\(suffix).\(fileExtension)",
                folder: folder,
                preservesExistingFileName: preservesExistingFileName,
                outputFormat: outputFormat
            )
            if unavailable.contains(LocalSourcePathResolver.pathIdentity(relativePath)) {
                suffix += 1
            } else {
                break
            }
        } while true
        return "\(base)-\(suffix).\(fileExtension)"
    }

    static func normalizedModuleNaming(
        _ modules: [RelayModule],
        localModuleDirectory: String,
        localModuleDirectories: [ModuleOutputFormat: String] = [:]
    ) -> [RelayModule] {
        let normalizedModules = modules.map { value in
            var module = value
            let localRoot = localModuleDirectories[module.outputFormat] ?? localModuleDirectory
            module.outputFolder = ModuleOutputFolder.normalized(module.outputFolder)
            if module.hasLocalStorageTarget {
                let hadLocalPath = module.localStorageRelativePath != nil
                if module.localStorageRelativePath == nil {
                    module.localStorageRelativePath = LocalSourcePathResolver.relativePath(
                        forSourceURL: module.sourceURL,
                        rootDirectoryPath: localRoot
                    ) ?? module.publishedRelativePath
                }
                module.preservesOutputFileName = true
                let currentOutputPath = module.publishedRelativePath
                let localSourcePath = LocalSourcePathResolver.relativePath(
                    forSourceURL: module.sourceURL,
                    rootDirectoryPath: localRoot
                )
                let localPath = module.localStorageRelativePath
                let shouldRestorePhysicalPath = localPath.map {
                    !hadLocalPath || localSourcePath == nil ||
                        LocalSourcePathResolver.pathIdentity(currentOutputPath) == LocalSourcePathResolver.pathIdentity($0)
                } ?? false
                if shouldRestorePhysicalPath,
                   let components = localPath?.split(separator: "/"),
                   let fileName = components.last {
                    module.outputFileName = FilenameSanitizer.outputFileName(from: String(fileName), format: module.outputFormat,
                        preservesExistingFileName: true)
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
            let preferred = FilenameSanitizer.outputFileName(from: preferredValue, format: module.outputFormat,
                preservesExistingFileName: preservesExistingFileName)
            let candidate = uniqueOutputFileName(
                preferredFileName: preferred,
                folder: module.outputFolder,
                unavailable: used,
                preservesExistingFileName: preservesExistingFileName,
                outputFormat: module.outputFormat
            )
            module.outputFileName = candidate
            used.insert(LocalSourcePathResolver.pathIdentity(module.publishedRelativePath))
            return module
        }
    }
}
