import Foundation

struct ModulePreviewDraft: Codable, Equatable, Sendable {
    var text: String
    var savedText: String

    func hasBaseChanged(comparedTo content: String) -> Bool {
        !savedText.utf16.elementsEqual(content.utf16)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text.utf16.elementsEqual(rhs.text.utf16) && lhs.savedText.utf16.elementsEqual(rhs.savedText.utf16)
    }
}

struct PendingModuleSave: Identifiable, Codable, Sendable {
    var id = UUID()
    var moduleID: UUID?
    var draft: ModuleDraft
    var refreshSource = false
    var errorMessage: String?
}

struct ModuleDraft: Codable, Sendable {
    var name = ""
    var sourceURL = ""
    var sourceFormat: ModuleSourceFormat = .automatic
    var outputFormat: ModuleOutputFormat = .surge
    var outputFileName = ""
    var category = ""
    var moduleDescription = ""
    var outputFolder = ModuleOutputFolder.root
    var storageTargets: Set<ModuleStorageLocation> = [.gitHub]
    var storageLocation: ModuleStorageLocation {
        get { storageTargets.count == 1 ? storageTargets.first! : (storageTargets.contains(.local) ? .local : .gitHub) }
        set { storageTargets = [newValue] }
    }
    var refreshIntervalMinutes: Int?
    var scriptHubOptions = ScriptHubOptions()
    var iconURL = ""

    init(defaultStorageLocation: ModuleStorageLocation = .gitHub) {
        storageTargets = [defaultStorageLocation]
    }

    init(module: RelayModule) {
        name = module.name
        sourceURL = module.sourceURL
        sourceFormat = module.sourceFormat
        outputFormat = module.outputFormat
        outputFileName = module.outputFileName
        category = module.category
        moduleDescription = module.moduleDescription
        outputFolder = module.outputFolder
        storageTargets = module.storageTargets
        refreshIntervalMinutes = module.refreshIntervalMinutes
        scriptHubOptions = module.scriptHubOptions
        iconURL = module.customIconURL ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case name, sourceURL, sourceFormat, outputFormat, outputFileName, category, moduleDescription
        case outputFolder, storageTargets, refreshIntervalMinutes, scriptHubOptions, iconURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        sourceURL = try container.decode(String.self, forKey: .sourceURL)
        sourceFormat = try container.decode(ModuleSourceFormat.self, forKey: .sourceFormat)
        outputFormat = try container.decodeIfPresent(ModuleOutputFormat.self, forKey: .outputFormat) ?? .surge
        outputFileName = try container.decode(String.self, forKey: .outputFileName)
        category = try container.decode(String.self, forKey: .category)
        moduleDescription = try container.decode(String.self, forKey: .moduleDescription)
        outputFolder = try container.decode(String.self, forKey: .outputFolder)
        storageTargets = try container.decode(Set<ModuleStorageLocation>.self, forKey: .storageTargets)
        refreshIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes)
        scriptHubOptions = try container.decode(ScriptHubOptions.self, forKey: .scriptHubOptions)
        iconURL = try container.decode(String.self, forKey: .iconURL)
    }

    var validationMessage: String? {
        if let refreshIntervalMinutes, !(0...10_080).contains(refreshIntervalMinutes) { return "刷新间隔必须为 0–10080 分钟；0 表示仅手动刷新。" }
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
        return FilenameSanitizer.outputFileName(from: preferred, format: outputFormat,
            preservesExistingFileName: URL(string: sourceValue)?.isFileURL == true || storageTargets.contains(.local))
    }

    func publishedRelativePath(for source: String? = nil) -> String {
        let sourceValue = source ?? sourceURL
        return ModuleOutputFolder.relativePath(
            fileName: normalizedOutputFileName(for: sourceValue),
            folder: outputFolder,
            preservesExistingFileName: URL(string: sourceValue)?.isFileURL == true || storageTargets.contains(.local),
            outputFormat: outputFormat
        )
    }
}
