import Foundation

@MainActor
extension AppModel {
    func testGitHub(showProgress: Bool = true) async {
        guard !isWorking || !showProgress else { return }
        if showProgress { beginWork(.testingGitHub) }
        defer { if showProgress { endWork(.testingGitHub) } }
        do {
            let token = ensureGitHubTokenLoaded(showStatusMessage: showProgress)
            guard !token.isEmpty else { throw RelayError.githubTokenMissing }
            let isPrivate = try await githubClient.test(settings: settings.github, token: token)
            if showProgress {
                guard shouldContinueCurrentWork() else { return }
            }
            settings.github.repositoryIsPrivate = isPrivate
            saveSettings()
            await refreshModuleOutputFolders(force: true)
            statusMessage = isPrivate ? "GitHub 私有仓库连接成功，需要配置 Cloudflare Worker" : "GitHub 公开仓库连接成功，将直接使用 Raw 地址"
        } catch {
            if showProgress, isCurrentWorkCancellation(error) { return }
            presentedError = error.localizedDescription
        }
    }
}
