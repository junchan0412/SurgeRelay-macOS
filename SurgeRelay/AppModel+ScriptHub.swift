import Foundation

@MainActor
extension AppModel {
    func refreshScriptHub(showProgress: Bool = true) async {
        guard !isWorking || !showProgress else { return }
        if showProgress { beginWork(.refreshingScriptHub) }
        await refreshScriptHubInternal()
        if showProgress {
            guard shouldContinueCurrentWork() else {
                endWork(.refreshingScriptHub)
                return
            }
        }
        if showProgress { endWork(.refreshingScriptHub) }
    }

    func refreshScriptHubInternal() async {
        statusMessage = "正在更新 App 内置 Script-Hub 引擎…"
        do {
            let result = try await upstreamService.fetchManagedModule(
                from: settings.scriptHubModuleURL,
                previousRevision: upstreamState.revision,
                previousUpstreamRevision: upstreamState.upstreamRevision,
                previousScriptHashes: upstreamState.scriptHashes
            )
            let missing = !(await engineStore.hasScript(named: "Rewrite-Parser.js"))
            if result.changed || missing {
                try await engineStore.save(scripts: result.scripts)
                upstreamState.lastUpdatedAt = .now
            }
            upstreamState.revision = result.revision
            upstreamState.sourceDescription = result.sourceDescription
            upstreamState.upstreamRevision = result.upstreamRevision
            upstreamState.scriptHashes = result.scriptHashes
            upstreamState.lastCheckedAt = .now
            upstreamState.lastError = nil
            PersistenceStore.saveUpstreamState(upstreamState)
            statusMessage = result.changed ? "内置 Script-Hub 引擎已更新至 \(result.revision)" : "内置 Script-Hub 引擎已是最新"
        } catch {
            upstreamState.lastCheckedAt = .now
            upstreamState.lastError = error.localizedDescription
            PersistenceStore.saveUpstreamState(upstreamState)
            let hasCache = await engineStore.hasScript(named: "Rewrite-Parser.js")
            statusMessage = hasCache ? "上游检查失败，继续使用 App 内缓存引擎" : "内置转换引擎尚不可用"
        }
    }
}
