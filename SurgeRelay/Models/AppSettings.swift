import Foundation

enum RefreshPolicy {
    static func isDue(lastUpdatedAt: Date?, intervalMinutes: Int, now: Date = .now) -> Bool {
        guard intervalMinutes > 0 else { return false }
        guard let lastUpdatedAt else { return true }
        return now.timeIntervalSince(lastUpdatedAt) >= Double(intervalMinutes * 60)
    }
}

struct GitHubSettings: Codable, Equatable, Sendable {
    var owner = "EEliberto"
    var repository = "Surge-Relay"
    var branch = "main"
    var directory = "modules"
    var publicBaseURL = ""
    var repositoryIsPrivate: Bool?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        owner = try container.decodeIfPresent(String.self, forKey: .owner) ?? "EEliberto"
        repository = try container.decodeIfPresent(String.self, forKey: .repository) ?? "Surge-Relay"
        branch = try container.decodeIfPresent(String.self, forKey: .branch) ?? "main"
        directory = try container.decodeIfPresent(String.self, forKey: .directory) ?? "modules"
        publicBaseURL = try container.decodeIfPresent(String.self, forKey: .publicBaseURL) ?? ""
        repositoryIsPrivate = try container.decodeIfPresent(Bool.self, forKey: .repositoryIsPrivate)
    }

    var isConfigured: Bool {
        validationMessage == nil
    }

    var validationMessage: String? {
        GitHubRepositoryValidator.validationMessage(owner: owner, repository: repository, branch: branch)
    }

    func rawURL(for fileName: String) -> URL? {
        guard isConfigured else { return nil }
        let components = [owner, repository, branch, directory, fileName]
            .filter { !$0.isEmpty }
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
        return URL(string: "https://raw.githubusercontent.com/\(components.joined(separator: "/"))")
    }

    func publicURL(for fileName: String) -> URL? {
        guard let repositoryIsPrivate else { return nil }
        guard repositoryIsPrivate else { return rawURL(for: fileName) }
        let base = publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { return nil }
        let path = fileName.split(separator: "/").map { component in
            String(component).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(component)
        }.joined(separator: "/")
        return URL(string: "\(base)/\(path)")
    }
}

enum GitHubRepositoryValidator {
    static func validationMessage(owner: String, repository: String, branch: String) -> String? {
        let owner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let repository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidOwner(owner) else {
            return "GitHub owner 只能包含字母、数字和连字符，且不能以连字符开头或结尾。"
        }
        guard isValidRepository(repository) else {
            return "GitHub 仓库名只能包含字母、数字、点、下划线和连字符。"
        }
        guard isValidBranch(branch) else {
            return "GitHub branch 不能包含空白、控制字符、连续斜杠、..、@{、反斜杠，且不能以斜杠开头或结尾。"
        }
        return nil
    }

    static func validatedRepositoryPath(owner: String, repository: String) throws -> String {
        guard validationMessage(owner: owner, repository: repository, branch: "main") == nil else {
            throw RelayError.githubNotConfigured
        }
        return "\(encodedPathComponent(owner.trimmingCharacters(in: .whitespacesAndNewlines)))/\(encodedPathComponent(repository.trimmingCharacters(in: .whitespacesAndNewlines)))"
    }

    private static func isValidOwner(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$"#, options: .regularExpression) != nil
    }

    private static func isValidRepository(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9._-]{1,100}$"#, options: .regularExpression) != nil
    }

    private static func isValidBranch(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 255,
              !value.hasPrefix("/"),
              !value.hasSuffix("/"),
              !value.contains("//"),
              !value.contains(".."),
              !value.contains("@{"),
              !value.contains("\\"),
              !value.hasSuffix(".lock") else {
            return false
        }
        for scalar in value.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar.value < 0x20 || scalar.value == 0x7f {
                return false
            }
        }
        return value.split(separator: "/").allSatisfy { component in
            !component.isEmpty && !component.hasPrefix(".") && !component.hasSuffix(".lock")
        }
    }

    private static func encodedPathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    // Kept only to find and remove files created by early development builds.
    var outputDirectory: String = AppSettings.defaultOutputDirectory
    var scriptHubModuleURL = AppSettings.defaultScriptHubModuleURL
    var combinedModuleEnabled = false
    var combinedModuleFileName = "Surge-Relay.sgmodule"
    // Retained so existing settings decode cleanly during migration.
    var scriptHubBaseURL = "http://script.hub"
    var managedEngineFileName = "Script-Hub-Relay.sgmodule"
    var automaticallyUpdateScriptHub = true
    var refreshIntervalMinutes = 60
    var automaticallyPublish = true
    var launchAtLogin = false
    var github = GitHubSettings()
    var githubToken = ""
    var storageMode: StorageMode = .gitHub
    var publishToLocal = false
    var publishToGitHub = true
    var localModuleDirectory: String = AppSettings.defaultLocalModuleRootDirectory
    var localPublishedRootDirectory: String?
    var localPublishedFilePaths: [String] = []
    var githubPublishedRepositoryKey: String?
    var githubPublishedFilePaths: [String] = []
    var customModuleOutputFolders: [String] = []
    var webServerEnabled = false
    var webServerPort = 8787
    var webServerAllowRemoteAccess = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outputDirectory = try container.decodeIfPresent(String.self, forKey: .outputDirectory) ?? Self.defaultOutputDirectory
        scriptHubModuleURL = Self.normalizedScriptHubModuleURL(
            try container.decodeIfPresent(String.self, forKey: .scriptHubModuleURL)
        )
        combinedModuleEnabled = try container.decodeIfPresent(Bool.self, forKey: .combinedModuleEnabled) ?? false
        combinedModuleFileName = try container.decodeIfPresent(String.self, forKey: .combinedModuleFileName) ?? "Surge-Relay.sgmodule"
        scriptHubBaseURL = try container.decodeIfPresent(String.self, forKey: .scriptHubBaseURL) ?? "http://script.hub"
        managedEngineFileName = try container.decodeIfPresent(String.self, forKey: .managedEngineFileName) ?? "Script-Hub-Relay.sgmodule"
        automaticallyUpdateScriptHub = try container.decodeIfPresent(Bool.self, forKey: .automaticallyUpdateScriptHub) ?? true
        refreshIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes) ?? 60
        automaticallyPublish = try container.decodeIfPresent(Bool.self, forKey: .automaticallyPublish) ?? true
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        github = try container.decodeIfPresent(GitHubSettings.self, forKey: .github) ?? GitHubSettings()
        githubToken = try container.decodeIfPresent(String.self, forKey: .githubToken) ?? ""
        storageMode = try container.decodeIfPresent(StorageMode.self, forKey: .storageMode) ?? .gitHub
        publishToLocal = try container.decodeIfPresent(Bool.self, forKey: .publishToLocal) ?? (storageMode == .local)
        publishToGitHub = try container.decodeIfPresent(Bool.self, forKey: .publishToGitHub) ?? (storageMode == .gitHub)
        if !publishToLocal && !publishToGitHub {
            publishToGitHub = true
            storageMode = .gitHub
        }
        localModuleDirectory = try container.decodeIfPresent(String.self, forKey: .localModuleDirectory) ?? Self.defaultLocalModuleRootDirectory
        localPublishedRootDirectory = try container.decodeIfPresent(String.self, forKey: .localPublishedRootDirectory)
        localPublishedFilePaths = try container.decodeIfPresent([String].self, forKey: .localPublishedFilePaths) ?? []
        githubPublishedRepositoryKey = try container.decodeIfPresent(String.self, forKey: .githubPublishedRepositoryKey)
        githubPublishedFilePaths = try container.decodeIfPresent([String].self, forKey: .githubPublishedFilePaths) ?? []
        customModuleOutputFolders = try container.decodeIfPresent([String].self, forKey: .customModuleOutputFolders) ?? []
        webServerEnabled = try container.decodeIfPresent(Bool.self, forKey: .webServerEnabled) ?? false
        webServerPort = try container.decodeIfPresent(Int.self, forKey: .webServerPort) ?? 8787
        webServerAllowRemoteAccess = try container.decodeIfPresent(Bool.self, forKey: .webServerAllowRemoteAccess) ?? false
    }

    static var defaultOutputDirectory: String {
        defaultConfigurationDirectory
    }

    static var defaultConfigurationDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/iCloud~com~nssurge~inc/Documents/Surge Relay", directoryHint: .isDirectory)
            .path
    }

    static var defaultLocalModuleRootDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/iCloud~com~nssurge~inc", directoryHint: .isDirectory)
            .path
    }

    static let defaultScriptHubModuleURL = "https://raw.githubusercontent.com/Script-Hub-Org/Script-Hub/6b4fb62240629d2fc66b08bc271f8c1f83a5dcd1/modules/script-hub.surge.sgmodule"

    static func normalizedScriptHubModuleURL(_ value: String?) -> String {
        guard let value else { return defaultScriptHubModuleURL }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultScriptHubModuleURL }
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "raw.githubusercontent.com" else {
            return trimmed
        }
        let components = url.path.split(separator: "/").map(String.init)
        guard components.count >= 4 else { return trimmed }
        let owner = components[0].lowercased()
        let repository = components[1].lowercased()
        let revision = components[2].lowercased()
        let modulePath = components.dropFirst(3).joined(separator: "/")
        let floatingRevisions = ["main", "master", "head"]
        guard owner == "script-hub-org",
              repository == "script-hub",
              modulePath == "modules/script-hub.surge.sgmodule",
              floatingRevisions.contains(revision) else {
            return trimmed
        }
        return defaultScriptHubModuleURL
    }

}

enum StorageMode: String, Codable, Sendable {
    case local
    case gitHub
}

struct ScriptHubUpstreamState: Codable, Equatable, Sendable {
    var revision: String?
    var sourceDescription: String?
    var upstreamRevision: String?
    var scriptHashes: [String: String] = [:]
    var lastCheckedAt: Date?
    var lastUpdatedAt: Date?
    var lastError: String?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decodeIfPresent(String.self, forKey: .revision)
        sourceDescription = try container.decodeIfPresent(String.self, forKey: .sourceDescription)
        upstreamRevision = try container.decodeIfPresent(String.self, forKey: .upstreamRevision)
        scriptHashes = try container.decodeIfPresent([String: String].self, forKey: .scriptHashes) ?? [:]
        lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        lastUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }
}

enum SidebarDestination: String, CaseIterable, Hashable, Identifiable {
    case modules
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modules: "模块"
        case .settings: "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .modules: "shippingbox"
        case .settings: "gear"
        }
    }
}
