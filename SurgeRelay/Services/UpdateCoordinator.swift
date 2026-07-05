import Foundation

enum UpdateCoordinator {
    static func shouldRefreshScriptHub(
        missingEngine: Bool,
        settings: AppSettings,
        upstreamState: ScriptHubUpstreamState
    ) -> Bool {
        missingEngine || (
            settings.automaticallyUpdateScriptHub &&
                RefreshPolicy.isDue(
                    lastUpdatedAt: upstreamState.lastCheckedAt,
                    intervalMinutes: settings.refreshIntervalMinutes
                )
        )
    }

    static func refreshIntervalSeconds(settings: AppSettings) -> Int? {
        guard settings.refreshIntervalMinutes > 0 else { return nil }
        return settings.refreshIntervalMinutes * 60
    }
}
