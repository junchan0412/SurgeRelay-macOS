import Foundation

struct WebPublishPreviewRequest: Decodable {
    var moduleIDs: Set<UUID>?
    var scope: String?
    var retryAttemptID: UUID?
}

struct WebActionTokenRequest: Decodable { var token: UUID }
struct WebSyncResolutionRequest: Decodable { var token: UUID; var direction: String }

struct WebPublishPreviewPayload: Encodable {
    var token: UUID
    var moduleIDs: Set<UUID>
    var scope: String
    var previews: [PublishPreview]
    var expiresAt: Date
}

struct WebPublishResultPayload: Encodable {
    var ok: Bool
    var message: String
    var attempt: SelectedPublishAttempt?
}

struct WebPublishingPayload: Encodable {
    var attempt: SelectedPublishAttempt?
    var canPublishToGitHub: Bool
    var localEnabled: Bool
}

struct WebSyncPayload: Encodable {
    var token: UUID
    var state: String
    var stateTitle: String
    var localContent: String
    var gitHubContent: String
    var localUpdatedAt: Date
    var gitHubUpdatedAt: Date
    var diff: ModuleLineDiff
}

struct WebPublishTicket {
    var token = UUID()
    var createdAt = Date.now
    var scope: String
    var moduleIDs: Set<UUID>
    var retryAttemptID: UUID?
    var generation: Int
    var settings: AppSettings
    var files: [PublishDestination: [PublishFile]]
    var previews: [PublishPreview]
    var pathPlan: GitHubPublishedPathPlan?
    var gitHubHead: String?
    var localHashes: [String: String]
    var retainsForNativeUI = false

    var expiresAt: Date { createdAt.addingTimeInterval(300) }
    var payload: WebPublishPreviewPayload {
        WebPublishPreviewPayload(token: token, moduleIDs: moduleIDs, scope: scope, previews: previews, expiresAt: expiresAt)
    }
}

struct WebVersionComparisonPayload: Encodable {
    var token: UUID
    var version: ModuleVersionRecord
    var diff: ModuleLineDiff
    var changedAssets: [String]
}
