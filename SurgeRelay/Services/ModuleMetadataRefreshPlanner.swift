import Foundation

struct ModuleMetadataRefreshPlan: Equatable, Sendable {
    var module: RelayModule
    var isChanged: Bool
    var preferredIconURL: URL?
    var shouldRefreshIconCache: Bool
}

enum ModuleMetadataRefreshPlanner {
    static func plan(
        module: RelayModule,
        cachedContent: String,
        convertedContent: String?,
        hasOverride: Bool,
        detectedIconURL: URL?
    ) -> ModuleMetadataRefreshPlan {
        var module = module
        var isChanged = false

        if hasOverride, module.overrideBaseHash == nil, let convertedContent {
            module.overrideBaseHash = Data(convertedContent.utf8).sha256String
            isChanged = true
        }

        if let subscription = ModuleMetadataParser.scriptHubSubscription(in: cachedContent) {
            isChanged = module.applyScriptHubSubscriptionMetadata(subscription) || isChanged
        }

        let preferredIconURL = module.customIconURL.flatMap(URL.init(string:)) ?? detectedIconURL
        let nextIconValue = preferredIconURL?.absoluteString
        let iconChanged = module.iconURL != nextIconValue
        if iconChanged {
            module.iconURL = nextIconValue
        }

        let resolvedFormat = ModuleNamingPlanner.detectedFormat(
            for: module.sourceFormat,
            source: module.sourceURL
        )
        let formatChanged = module.detectedSourceFormat != resolvedFormat
        if formatChanged {
            module.detectedSourceFormat = resolvedFormat
        }

        isChanged = isChanged || iconChanged || formatChanged
        return ModuleMetadataRefreshPlan(
            module: module,
            isChanged: isChanged,
            preferredIconURL: preferredIconURL,
            shouldRefreshIconCache: iconChanged
        )
    }
}
