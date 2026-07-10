import Foundation

struct ModuleDraft: Sendable {
    var name = ""
    var sourceURL = ""
    var sourceFormat: ModuleSourceFormat = .automatic
    var outputFileName = ""
    var category = ""
    var outputFolder = ModuleOutputFolder.root
    var storageLocation: ModuleStorageLocation = .gitHub
    var publishesStandalone = true
    var isEnabled = false
    var scriptHubOptions = ScriptHubOptions()
    var iconURL = ""

    init(defaultStorageLocation: ModuleStorageLocation = .gitHub) {
        storageLocation = defaultStorageLocation
    }

    init(module: RelayModule) {
        name = module.name
        sourceURL = module.sourceURL
        sourceFormat = module.sourceFormat
        outputFileName = module.outputFileName
        category = module.category
        outputFolder = module.outputFolder
        storageLocation = module.storageLocation
        publishesStandalone = module.publishesStandalone
        isEnabled = module.isEnabled
        scriptHubOptions = module.scriptHubOptions
        iconURL = module.customIconURL ?? ""
    }

    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入模块名称。" }
        let trimmedIcon = iconURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedIcon.isEmpty {
            guard let iconURL = URL(string: trimmedIcon),
                  ["http", "https"].contains(iconURL.scheme?.lowercased()),
                  iconURL.host?.isEmpty == false else {
                return "图标 URL 仅支持 HTTP 或 HTTPS 地址。"
            }
        }
        guard let url = URL(string: sourceURL) else {
            return "请输入有效的 HTTP、HTTPS 或本地文件来源地址。"
        }
        if url.isFileURL {
            guard sourceFormat.isNativeSurgeModule(for: url) else {
                return "本地文件来源仅支持 Surge .sgmodule。"
            }
            return nil
        }
        guard ["http", "https"].contains(url.scheme?.lowercased()) else {
            return "请输入有效的 HTTP、HTTPS 或本地文件来源地址。"
        }
        return nil
    }

    var normalizedCustomIconURL: String? {
        let trimmed = iconURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func normalizedOutputFileName(for source: String? = nil) -> String {
        let sourceValue = source ?? sourceURL
        let explicitOutput = outputFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferred: String
        if !explicitOutput.isEmpty {
            preferred = explicitOutput
        } else if !displayName.isEmpty {
            preferred = displayName
        } else {
            preferred = FilenameSanitizer.suggestedName(from: sourceValue)
        }
        return URL(string: sourceValue)?.isFileURL == true
            || storageLocation == .local
            ? FilenameSanitizer.existingSgmoduleName(from: preferred)
            : FilenameSanitizer.sgmoduleName(from: preferred)
    }

    func publishedRelativePath(for source: String? = nil) -> String {
        let sourceValue = source ?? sourceURL
        return ModuleOutputFolder.relativePath(
            fileName: normalizedOutputFileName(for: sourceValue),
            folder: outputFolder,
            preservesExistingFileName: URL(string: sourceValue)?.isFileURL == true || storageLocation == .local
        )
    }
}
