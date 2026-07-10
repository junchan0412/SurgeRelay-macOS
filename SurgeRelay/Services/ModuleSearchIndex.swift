import Foundation

struct ModuleSearchContentIndexState: Equatable, Sendable {
    var contentIndex: [UUID: String] = [:]
    var contentIndexCacheKeys: [UUID: String] = [:]

    static let empty = ModuleSearchContentIndexState()
}

struct ModuleSearchContentLoadPlan: Sendable {
    var retainedState: ModuleSearchContentIndexState
    var modulesToLoad: [RelayModule]

    var isIdle: Bool {
        retainedState == .empty && modulesToLoad.isEmpty
    }
}

enum ModuleSearchIndex {
    static func normalizedQuery(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func contentIndexToken(for modules: [RelayModule], query: String) -> String {
        let query = normalizedQuery(query)
        guard !query.isEmpty else { return "idle" }
        return "active|\(query)|" + modules
            .map { "\($0.id.uuidString):\($0.contentHash ?? "")" }
            .joined(separator: "|")
    }

    static func contentCacheKey(for module: RelayModule) -> String {
        module.contentHash ?? ""
    }

    static func cachedContent(
        for module: RelayModule,
        contentIndex: [UUID: String],
        contentIndexCacheKeys: [UUID: String]
    ) -> String? {
        guard contentIndexCacheKeys[module.id] == contentCacheKey(for: module) else {
            return nil
        }
        return contentIndex[module.id]
    }

    static func metadataText(for module: RelayModule) -> String {
        text(for: module, cachedContent: nil)
    }

    static func text(for module: RelayModule, cachedContent: String? = nil) -> String {
        var parts = [
            module.name,
            module.sourceURL,
            module.outputFileName,
            module.publishedRelativePath,
            module.sourceFormatDisplayTitle,
            module.category,
            module.outputFolder,
            ModuleOutputFolder.displayTitle(for: module.outputFolder),
            module.displayStorageLocationTitle,
            module.standaloneStorageDetail,
            module.initialSource.title,
            module.relationshipSummary,
            module.publishesStandalone ? "独立模块" : "不发布独立模块",
            module.state.title,
        ]
        if let iconURL = module.iconURL { parts.append(iconURL) }
        if let customIconURL = module.customIconURL { parts.append(customIconURL) }
        if let lastError = module.lastError { parts.append(lastError) }
        if let subscription = module.scriptHubSubscription {
            parts.append(subscription.subscriptionURL)
            parts.append(subscription.originalURL)
            parts.append(subscription.displaySummary)
            if let outputName = subscription.outputName { parts.append(outputName) }
            if let sourceType = subscription.sourceType { parts.append(sourceType) }
            if let target = subscription.target { parts.append(target) }
            if let category = subscription.category { parts.append(category) }
        }
        parts.append(contentsOf: module.argumentOverrides.flatMap { [$0.key, $0.value] })
        if let data = try? JSONEncoder().encode(module.scriptHubOptions),
           let text = String(data: data, encoding: .utf8) {
            parts.append(text)
        }
        if let cachedContent {
            parts.append(cachedContent)
        }
        return parts.joined(separator: "\n").lowercased()
    }

    static func shouldLoadContent(for module: RelayModule, query: String, cachedContent: String?) -> Bool {
        let query = normalizedQuery(query)
        guard !query.isEmpty else { return false }
        guard cachedContent == nil else { return false }
        return !metadataText(for: module).contains(query)
    }

    static func contentLoadPlan(
        modules: [RelayModule],
        query: String,
        state: ModuleSearchContentIndexState
    ) -> ModuleSearchContentLoadPlan {
        let query = normalizedQuery(query)
        guard !query.isEmpty else {
            return ModuleSearchContentLoadPlan(retainedState: .empty, modulesToLoad: [])
        }
        var retainedState = ModuleSearchContentIndexState()
        var modulesToLoad: [RelayModule] = []
        for module in modules {
            let cacheKey = contentCacheKey(for: module)
            let cachedContent = cachedContent(
                for: module,
                contentIndex: state.contentIndex,
                contentIndexCacheKeys: state.contentIndexCacheKeys
            )
            if let cachedContent {
                retainedState.contentIndex[module.id] = cachedContent
                retainedState.contentIndexCacheKeys[module.id] = cacheKey
            }
            if shouldLoadContent(for: module, query: query, cachedContent: cachedContent) {
                modulesToLoad.append(module)
            }
        }
        return ModuleSearchContentLoadPlan(
            retainedState: retainedState,
            modulesToLoad: modulesToLoad
        )
    }
}
