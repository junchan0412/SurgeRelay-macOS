import Foundation

enum ModuleSyncResolution: Sendable {
    case localWins
    case githubWins
}

enum ModuleSyncPlanner {
    static func conflict(
        localData: Data?,
        localUpdatedAt: Date?,
        github: GitHubClient.FileSnapshot?,
        now: Date = .now
    ) -> ModuleSyncConflictMetadata? {
        guard let localData, let localUpdatedAt, let github else { return nil }
        let localHash = localData.sha256String
        guard localHash != github.contentHash else { return nil }
        return ModuleSyncConflictMetadata(
            localHash: localHash,
            githubHash: github.contentHash,
            localUpdatedAt: localUpdatedAt,
            githubUpdatedAt: github.updatedAt,
            detectedAt: now
        )
    }
}
