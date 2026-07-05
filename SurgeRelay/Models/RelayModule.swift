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

enum ModuleStorageLocation: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case gitHub

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: "本地模块"
        case .gitHub: "GitHub 模块"
        }
    }

    var detail: String {
        switch self {
        case .local: "储存在本地模块根目录"
        case .gitHub: "储存在 GitHub 模块目录"
        }
    }

    var systemImage: String {
        switch self {
        case .local: "folder"
        case .gitHub: "cloud"
        }
    }
}

enum ModuleSourceOrigin: Equatable, Sendable {
    case localSurgeFile
    case remote(ModuleSourceFormat)
    case invalid

    var title: String {
        switch self {
        case .localSurgeFile:
            "本地 Surge 模块"
        case .remote(let format):
            switch format {
            case .automatic:
                "远程来源"
            case .quantumultX:
                "远程 Quantumult X"
            case .loon:
                "远程 Loon"
            case .surge:
                "远程 Surge 模块"
            }
        case .invalid:
            "缺少有效来源"
        }
    }

    var systemImage: String {
        switch self {
        case .localSurgeFile: "doc"
        case .remote: "link"
        case .invalid: "exclamationmark.triangle"
        }
    }

    var isRemote: Bool {
        if case .remote = self { return true }
        return false
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
    var storageLocation: ModuleStorageLocation
    var localStorageRelativePath: String?
    var preservesOutputFileName: Bool
    var publishesStandalone: Bool
    var isEnabled: Bool
    var scriptHubOptions: ScriptHubOptions
    var argumentOverrides: [String: String]
    var iconURL: String?
    var customIconURL: String?
    var scriptHubSubscription: ScriptHubSubscriptionInfo?
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
        storageLocation: ModuleStorageLocation? = nil,
        localStorageRelativePath: String? = nil,
        preservesOutputFileName: Bool? = nil,
        publishesStandalone: Bool = true,
        isEnabled: Bool = false,
        scriptHubOptions: ScriptHubOptions = ScriptHubOptions(),
        argumentOverrides: [String: String] = [:],
        iconURL: String? = nil,
        customIconURL: String? = nil,
        scriptHubSubscription: ScriptHubSubscriptionInfo? = nil,
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
        let inferredStorageLocation = storageLocation
            ?? (URL(string: sourceURL)?.isFileURL == true ? .local : .gitHub)
        let shouldPreserveOutputFileName = preservesOutputFileName
            ?? (inferredStorageLocation == .local || URL(string: sourceURL)?.isFileURL == true)
        self.id = id
        self.name = name
        self.sourceURL = sourceURL
        self.sourceFormat = sourceFormat
        self.outputFileName = Self.normalizedOutputFileName(
            outputFileName,
            preservesExistingFileName: shouldPreserveOutputFileName
        )
        self.category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        self.outputFolder = ModuleOutputFolder.normalized(outputFolder)
        self.storageLocation = inferredStorageLocation
        self.localStorageRelativePath = Self.normalizedOptionalRelativePath(localStorageRelativePath)
        self.preservesOutputFileName = shouldPreserveOutputFileName
        self.publishesStandalone = publishesStandalone
        self.isEnabled = isEnabled
        self.scriptHubOptions = scriptHubOptions
        self.argumentOverrides = argumentOverrides
        self.iconURL = iconURL
        self.customIconURL = customIconURL
        self.scriptHubSubscription = scriptHubSubscription
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
        case id, name, sourceURL, sourceFormat, outputFileName, category, outputFolder
        case storageLocation, localStorageRelativePath, preservesOutputFileName
        case publishesStandalone, isEnabled, scriptHubOptions, argumentOverrides, iconURL, customIconURL, scriptHubSubscription, detectedSourceFormat
        case createdAt, lastUpdatedAt, contentHash, sourceETag, sourceLastModified, sourceContentHash, sourceCheckedAt
        case conversionEngineRevision, overrideBaseHash, hasOverrideConflict, state, lastError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sourceURL = try container.decode(String.self, forKey: .sourceURL)
        sourceFormat = try container.decodeIfPresent(ModuleSourceFormat.self, forKey: .sourceFormat) ?? .automatic
        storageLocation = try container.decodeIfPresent(ModuleStorageLocation.self, forKey: .storageLocation)
            ?? (URL(string: sourceURL)?.isFileURL == true ? .local : .gitHub)
        localStorageRelativePath = Self.normalizedOptionalRelativePath(
            try container.decodeIfPresent(String.self, forKey: .localStorageRelativePath)
        )
        preservesOutputFileName = try container.decodeIfPresent(Bool.self, forKey: .preservesOutputFileName)
            ?? (storageLocation == .local || URL(string: sourceURL)?.isFileURL == true)
        let decodedOutputFileName = try container.decodeIfPresent(String.self, forKey: .outputFileName)
            ?? FilenameSanitizer.suggestedName(from: sourceURL)
        outputFileName = Self.normalizedOutputFileName(
            decodedOutputFileName,
            preservesExistingFileName: preservesOutputFileName
        )
        category = try container.decodeIfPresent(String.self, forKey: .category)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        outputFolder = ModuleOutputFolder.normalized(
            try container.decodeIfPresent(String.self, forKey: .outputFolder) ?? ModuleOutputFolder.root
        )
        publishesStandalone = try container.decodeIfPresent(Bool.self, forKey: .publishesStandalone) ?? true
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        scriptHubOptions = try container.decodeIfPresent(ScriptHubOptions.self, forKey: .scriptHubOptions) ?? ScriptHubOptions()
        argumentOverrides = try container.decodeIfPresent([String: String].self, forKey: .argumentOverrides) ?? [:]
        iconURL = try container.decodeIfPresent(String.self, forKey: .iconURL)
        customIconURL = try container.decodeIfPresent(String.self, forKey: .customIconURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if customIconURL?.isEmpty == true { customIconURL = nil }
        scriptHubSubscription = try container.decodeIfPresent(ScriptHubSubscriptionInfo.self, forKey: .scriptHubSubscription)
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

    var sourceOrigin: ModuleSourceOrigin {
        guard let url = URL(string: effectiveOriginalSourceURL) else { return .invalid }
        if url.isFileURL { return .localSurgeFile }
        guard ["http", "https"].contains(url.scheme?.lowercased()) else { return .invalid }
        let resolved = detectedSourceFormat ?? sourceFormat.resolvedFormat(for: url)
        return .remote(resolved)
    }

    var relationshipSummary: String {
        "\(storageLocation.title) · \(sourceOrigin.title)"
    }

    var effectiveOriginalSourceURL: String {
        scriptHubSubscription?.originalURL ?? sourceURL
    }

    var hasRemoteOriginalSource: Bool {
        guard let scheme = URL(string: effectiveOriginalSourceURL)?.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    mutating func applyScriptHubSubscriptionMetadata(_ subscription: ScriptHubSubscriptionInfo) -> Bool {
        var changed = false
        let sourceWasFile = URL(string: sourceURL)?.isFileURL == true
        let sourceWasScriptHub = sourceURL.hasPrefix("http://script.hub/") || sourceURL.hasPrefix("https://script.hub/")

        if scriptHubSubscription != subscription {
            scriptHubSubscription = subscription
            changed = true
        }
        if sourceWasFile || sourceWasScriptHub {
            if sourceURL != subscription.originalURL {
                sourceURL = subscription.originalURL
                if sourceWasFile {
                    storageLocation = .local
                    preservesOutputFileName = true
                }
                sourceETag = nil
                sourceLastModified = nil
                sourceContentHash = nil
                sourceCheckedAt = nil
                conversionEngineRevision = nil
                changed = true
            }
        }
        if let subscriptionSourceFormat = subscription.sourceFormat,
           sourceWasFile || sourceFormat == .automatic || sourceFormat == .surge {
            if sourceFormat != subscriptionSourceFormat {
                sourceFormat = subscriptionSourceFormat
                changed = true
            }
        }
        if sourceWasFile || scriptHubOptions == ScriptHubOptions() {
            if scriptHubOptions != subscription.options {
                scriptHubOptions = subscription.options
                changed = true
            }
        }
        if category.isEmpty, let subscriptionCategory = subscription.category, !subscriptionCategory.isEmpty {
            category = subscriptionCategory
            changed = true
        }
        return changed
    }

    var publishedRelativePath: String {
        ModuleOutputFolder.relativePath(
            fileName: outputFileName,
            folder: outputFolder,
            preservesExistingFileName: preservesOutputFileName
        )
    }

    private static func normalizedOutputFileName(_ value: String, preservesExistingFileName: Bool) -> String {
        preservesExistingFileName
            ? FilenameSanitizer.existingSgmoduleName(from: value)
            : FilenameSanitizer.sgmoduleName(from: value)
    }

    private static func normalizedOptionalRelativePath(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = ModuleOutputFolder.normalized(value)
        return normalized.isEmpty ? nil : normalized
    }
}
