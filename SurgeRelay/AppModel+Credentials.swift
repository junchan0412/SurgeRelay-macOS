import Foundation

@MainActor
extension AppModel {
    @discardableResult
    func ensureGitHubTokenLoaded(showStatusMessage: Bool = false) -> String {
        let legacyToken = settings.githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldLoad = githubTokenStorageStatus == .notChecked ||
            (githubTokenStorageStatus == .legacyConfigurationFallback && !legacyToken.isEmpty)
        guard shouldLoad else {
            return githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let tokenLoad = CredentialTokenCoordinator.loadGitHubToken(migratingLegacyToken: settings.githubToken)
        githubToken = tokenLoad.token
        githubTokenStorageStatus = tokenLoad.storageStatus
        if tokenLoad.shouldClearLegacyToken {
            settings.githubToken = ""
            PersistenceStore.saveSettings(settings)
        }
        if showStatusMessage, let message = tokenLoad.statusMessage {
            statusMessage = message
        }
        return tokenLoad.token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func saveGitHubToken() {
        githubToken = githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try LocalCredentialStore.saveGitHubToken(githubToken)
            settings.githubToken = ""
            githubTokenStorageStatus = githubToken.isEmpty ? .notConfigured : .encrypted
            PersistenceStore.saveSettings(settings)
            statusMessage = githubToken.isEmpty ? "GitHub Token 已从本地加密存储移除" : "GitHub Token 已保存到本地加密文件"
        } catch {
            githubTokenStorageStatus = githubToken.isEmpty ? .unavailable : .memoryOnly
            presentedError = "无法保存 GitHub Token：\(error.localizedDescription)"
            statusMessage = "GitHub Token 未保存"
        }
    }
}
