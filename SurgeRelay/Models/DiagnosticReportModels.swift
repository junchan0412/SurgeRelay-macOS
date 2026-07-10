import Foundation

struct DiagnosticModuleSnapshot: Codable, Sendable {
    var id: UUID
    var name: String
    var sourceURL: String
    var initialSourceURL: String?
    var updateSourceURL: String
    var storageLocation: String
    var storageLocationTitle: String
    var initialSourceTitle: String
    var relationshipSummary: String
    var localStorageRelativePath: String?
    var enabled: Bool
    var state: String
    var lastUpdatedAt: Date?
    var sourceCheckedAt: Date?
    var lastError: String?
    var hasOverrideConflict: Bool
}

struct DiagnosticReport: Codable, Sendable {
    var generatedAt: Date
    var appVersion: String
    var operatingSystem: String
    var installation: InstallationDiagnosticSnapshot
    var credentials: CredentialDiagnosticSnapshot
    var engineRevision: String?
    var storageMode: String
    var localModuleRoot: LocalModuleRootDiagnosticSnapshot
    var githubRepository: String
    var webServerEnabled: Bool
    var webServerState: String
    var webServerPort: Int
    var webServerAllowRemoteAccess: Bool
    var webServerAccessMode: String
    var webManagementURL: String?
    var webAccessTokenStorageStatus: String
    var automaticPublishScheduledAt: Date?
    var automaticPublishRunsAt: Date?
    var latestGitHubPublish: GitHubPublishSnapshot?
    var activeWorkKind: String
    var activeWorkTitle: String?
    var activeWorkStatus: String?
    var activeWorkStartedAt: Date?
    var activeWorkBlocksUpdates: Bool
    var activeWorkCanCancel: Bool
    var activeWorkCancellationRequested: Bool
    var modules: [DiagnosticModuleSnapshot]
    var history: [UpdateHistoryEntry]
}
