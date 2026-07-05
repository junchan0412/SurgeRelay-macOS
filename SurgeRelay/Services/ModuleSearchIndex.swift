import Foundation

enum ModuleSearchIndex {
    static func normalizedQuery(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
            module.storageLocation.title,
            module.storageLocation.detail,
            module.sourceOrigin.title,
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
}
