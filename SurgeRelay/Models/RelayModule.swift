import Foundation

enum ModuleSourceIdentity {
    static func canonicalValue(for source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.isFileURL {
            return url.standardizedFileURL.absoluteString
        }
        guard var components = URLComponents(string: trimmed) else { return trimmed }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil

        if (components.scheme == "https" && components.port == 443) ||
            (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.percentEncodedPath.isEmpty {
            components.percentEncodedPath = "/"
        }

        return components.string ?? trimmed
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        canonicalValue(for: lhs) == canonicalValue(for: rhs)
    }
}

enum ModuleOutputFolder {
    static let root = ""

    static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        guard !trimmed.isEmpty else { return root }

        let components = trimmed
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return components.joined(separator: "/")
    }

    static func displayTitle(for folder: String) -> String {
        let normalized = normalized(folder)
        return normalized.isEmpty ? "根目录" : normalized
    }

    static func relativePath(fileName: String, folder: String) -> String {
        let normalizedFolder = normalized(folder)
        let normalizedFileName = FilenameSanitizer.sgmoduleName(from: fileName)
        return [normalizedFolder, normalizedFileName].filter { !$0.isEmpty }.joined(separator: "/")
    }

    static func components(_ folder: String) -> [String] {
        normalized(folder).split(separator: "/").map(String.init)
    }

    static func options(from folders: [String], preserving selected: String? = nil) -> [String] {
        var values = Set([root])
        for folder in folders {
            values.insert(normalized(folder))
        }
        if let selected {
            values.insert(normalized(selected))
        }
        return values.sorted { lhs, rhs in
            if lhs.isEmpty { return true }
            if rhs.isEmpty { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}

enum ModuleSourceFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case quantumultX
    case loon
    case surge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "自动识别"
        case .quantumultX: "Quantumult X 重写"
        case .loon: "Loon 插件"
        case .surge: "Surge 模块"
        }
    }

    var shortTitle: String {
        switch self {
        case .automatic: "自动"
        case .quantumultX: "Quantumult X"
        case .loon: "Loon"
        case .surge: "Surge"
        }
    }

    func resolvedFormat(for sourceURL: URL) -> ModuleSourceFormat {
        guard self == .automatic else { return self }
        let path = sourceURL.path.lowercased()
        switch sourceURL.pathExtension.lowercased() {
        case "sgmodule": return .surge
        case "plugin", "lpx": return .loon
        default: break
        }
        if path.contains("/loon/") { return .loon }
        if path.contains("/quantumultx/") || path.contains("/quantumult-x/") || path.contains("/qx/") {
            return .quantumultX
        }
        return .quantumultX
    }

    func scriptHubType(for sourceURL: URL) -> String {
        switch resolvedFormat(for: sourceURL) {
        case .quantumultX: "qx-rewrite"
        case .loon: "loon-plugin"
        case .surge: "surge-module"
        case .automatic: "qx-rewrite"
        }
    }

    func isNativeSurgeModule(for sourceURL: URL) -> Bool {
        resolvedFormat(for: sourceURL) == .surge
    }
}

enum ModuleUpdateState: String, Codable, Sendable {
    case never
    case updating
    case current
    case failed

    var title: String {
        switch self {
        case .never: "尚未更新"
        case .updating: "正在更新"
        case .current: "已是最新"
        case .failed: "更新失败"
        }
    }
}

struct RelayModule: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var sourceURL: String
    var sourceFormat: ModuleSourceFormat
    var outputFileName: String
    var category: String
    var outputFolder: String
    var publishesStandalone: Bool
    var isEnabled: Bool
    var scriptHubOptions: ScriptHubOptions
    var argumentOverrides: [String: String]
    var iconURL: String?
    var detectedSourceFormat: ModuleSourceFormat?
    var createdAt: Date
    var lastUpdatedAt: Date?
    var contentHash: String?
    var sourceETag: String?
    var sourceLastModified: String?
    var sourceContentHash: String?
    var sourceCheckedAt: Date?
    var conversionEngineRevision: String?
    var overrideBaseHash: String?
    var hasOverrideConflict: Bool
    var state: ModuleUpdateState
    var lastError: String?

    init(
        id: UUID = UUID(),
        name: String,
        sourceURL: String,
        sourceFormat: ModuleSourceFormat = .automatic,
        outputFileName: String,
        category: String = "",
        outputFolder: String = ModuleOutputFolder.root,
        publishesStandalone: Bool = true,
        isEnabled: Bool = true,
        scriptHubOptions: ScriptHubOptions = ScriptHubOptions(),
        argumentOverrides: [String: String] = [:],
        iconURL: String? = nil,
        detectedSourceFormat: ModuleSourceFormat? = nil,
        createdAt: Date = .now,
        lastUpdatedAt: Date? = nil,
        contentHash: String? = nil,
        sourceETag: String? = nil,
        sourceLastModified: String? = nil,
        sourceContentHash: String? = nil,
        sourceCheckedAt: Date? = nil,
        conversionEngineRevision: String? = nil,
        overrideBaseHash: String? = nil,
        hasOverrideConflict: Bool = false,
        state: ModuleUpdateState = .never,
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.sourceURL = sourceURL
        self.sourceFormat = sourceFormat
        self.outputFileName = FilenameSanitizer.sgmoduleName(from: outputFileName)
        self.category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        self.outputFolder = ModuleOutputFolder.normalized(outputFolder)
        self.publishesStandalone = publishesStandalone
        self.isEnabled = isEnabled
        self.scriptHubOptions = scriptHubOptions
        self.argumentOverrides = argumentOverrides
        self.iconURL = iconURL
        self.detectedSourceFormat = detectedSourceFormat
        self.createdAt = createdAt
        self.lastUpdatedAt = lastUpdatedAt
        self.contentHash = contentHash
        self.sourceETag = sourceETag
        self.sourceLastModified = sourceLastModified
        self.sourceContentHash = sourceContentHash
        self.sourceCheckedAt = sourceCheckedAt
        self.conversionEngineRevision = conversionEngineRevision
        self.overrideBaseHash = overrideBaseHash
        self.hasOverrideConflict = hasOverrideConflict
        self.state = state
        self.lastError = lastError
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sourceURL, sourceFormat, outputFileName, category, outputFolder, publishesStandalone, isEnabled, scriptHubOptions, argumentOverrides, iconURL, detectedSourceFormat
        case createdAt, lastUpdatedAt, contentHash, sourceETag, sourceLastModified, sourceContentHash, sourceCheckedAt
        case conversionEngineRevision, overrideBaseHash, hasOverrideConflict, state, lastError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sourceURL = try container.decode(String.self, forKey: .sourceURL)
        sourceFormat = try container.decodeIfPresent(ModuleSourceFormat.self, forKey: .sourceFormat) ?? .automatic
        outputFileName = try container.decodeIfPresent(String.self, forKey: .outputFileName)
            ?? FilenameSanitizer.suggestedName(from: sourceURL)
        category = try container.decodeIfPresent(String.self, forKey: .category)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        outputFolder = ModuleOutputFolder.normalized(
            try container.decodeIfPresent(String.self, forKey: .outputFolder) ?? ModuleOutputFolder.root
        )
        publishesStandalone = try container.decodeIfPresent(Bool.self, forKey: .publishesStandalone) ?? true
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        scriptHubOptions = try container.decodeIfPresent(ScriptHubOptions.self, forKey: .scriptHubOptions) ?? ScriptHubOptions()
        argumentOverrides = try container.decodeIfPresent([String: String].self, forKey: .argumentOverrides) ?? [:]
        iconURL = try container.decodeIfPresent(String.self, forKey: .iconURL)
        detectedSourceFormat = try container.decodeIfPresent(ModuleSourceFormat.self, forKey: .detectedSourceFormat)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        lastUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
        sourceETag = try container.decodeIfPresent(String.self, forKey: .sourceETag)
        sourceLastModified = try container.decodeIfPresent(String.self, forKey: .sourceLastModified)
        sourceContentHash = try container.decodeIfPresent(String.self, forKey: .sourceContentHash)
        sourceCheckedAt = try container.decodeIfPresent(Date.self, forKey: .sourceCheckedAt)
        conversionEngineRevision = try container.decodeIfPresent(String.self, forKey: .conversionEngineRevision)
        overrideBaseHash = try container.decodeIfPresent(String.self, forKey: .overrideBaseHash)
        hasOverrideConflict = try container.decodeIfPresent(Bool.self, forKey: .hasOverrideConflict) ?? false
        state = try container.decodeIfPresent(ModuleUpdateState.self, forKey: .state) ?? .never
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }

    var sourceFormatDisplayTitle: String {
        guard sourceFormat == .automatic else { return sourceFormat.title }
        let resolved = detectedSourceFormat ?? URL(string: sourceURL).map { sourceFormat.resolvedFormat(for: $0) }
        guard let resolved else { return sourceFormat.title }
        return "自动识别（\(resolved.shortTitle)）"
    }

    var publishedRelativePath: String {
        ModuleOutputFolder.relativePath(fileName: outputFileName, folder: outputFolder)
    }
}

struct ModuleDraft: Sendable {
    var name = ""
    var sourceURL = ""
    var sourceFormat: ModuleSourceFormat = .automatic
    var outputFileName = ""
    var category = ""
    var outputFolder = ModuleOutputFolder.root
    var publishesStandalone = true
    var isEnabled = true
    var scriptHubOptions = ScriptHubOptions()

    init() {}

    init(module: RelayModule) {
        name = module.name
        sourceURL = module.sourceURL
        sourceFormat = module.sourceFormat
        outputFileName = module.outputFileName
        category = module.category
        outputFolder = module.outputFolder
        publishesStandalone = module.publishesStandalone
        isEnabled = module.isEnabled
        scriptHubOptions = module.scriptHubOptions
    }

    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入模块名称。" }
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
}
