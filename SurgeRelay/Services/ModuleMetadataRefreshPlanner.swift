import Foundation

struct ModuleMetadataRefreshPlan: Equatable, Sendable {
    var module: RelayModule
    var isChanged: Bool
    var preferredIconURL: URL?
    var shouldRefreshIconCache: Bool
}

struct ModuleSuccessfulConversionPlan: Equatable, Sendable {
    var module: RelayModule
    var preferredIconURL: URL?
    var shouldRefreshIconCache: Bool
    var contentChanged: Bool
    var historyMessage: String
}

struct ModuleUnchangedCachedContentPlan: Equatable, Sendable {
    var module: RelayModule
    var historyMessage: String
}

enum ModuleMetadataRefreshPlanner {
    static func plan(
        module: RelayModule,
        cachedContent: String,
        convertedContent: String?,
        authoritativeSubscription: ScriptHubSubscriptionInfo? = nil,
        hasOverride: Bool,
        detectedIconURL: URL?
    ) -> ModuleMetadataRefreshPlan {
        var module = module
        var isChanged = false

        if hasOverride, module.overrideBaseHash == nil, let convertedContent {
            module.overrideBaseHash = Data(convertedContent.utf8).sha256String
            isChanged = true
        }

        let metadataContent = convertedContent ?? cachedContent
        let subscription = authoritativeSubscription
            ?? ModuleMetadataParser.scriptHubSubscription(in: metadataContent)
        if let subscription {
            isChanged = module.reconcileScriptHubSubscriptionMetadata(subscription) || isChanged
        }
        isChanged = module.repairSourceFormatFromUpdateSource() || isChanged

        let preferredIconURL = module.customIconURL.flatMap(URL.init(string:)) ?? detectedIconURL
        let nextIconValue = preferredIconURL?.absoluteString
        let iconChanged = module.iconURL != nextIconValue
        if iconChanged {
            module.iconURL = nextIconValue
        }

        let resolvedFormat = ModuleNamingPlanner.detectedFormat(
            for: module.sourceFormat,
            source: module.updateSourceURL
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

    static func successfulConversionPlan(
        module: RelayModule,
        revisionSnapshot: SourceRevisionSnapshot?,
        nativeModule: Bool,
        engineRevision: String?,
        convertedContent: String,
        effectiveContent: String,
        hasOverride: Bool,
        detectedIconURL: URL?,
        nextContentHash: String,
        updatedAt: Date = .now
    ) -> ModuleSuccessfulConversionPlan {
        var module = module
        if let revisionSnapshot {
            module.sourceETag = revisionSnapshot.etag
            module.sourceLastModified = revisionSnapshot.lastModified
            module.sourceContentHash = revisionSnapshot.contentHash
            module.sourceCheckedAt = revisionSnapshot.checkedAt
        } else {
            module.sourceCheckedAt = updatedAt
        }
        module.conversionEngineRevision = nativeModule ? nil : engineRevision

        if hasOverride, let baseHash = module.overrideBaseHash {
            module.hasOverrideConflict = baseHash != Data(convertedContent.utf8).sha256String
        } else {
            module.hasOverrideConflict = false
        }

        if let subscription = ModuleMetadataParser.scriptHubSubscription(in: convertedContent) {
            _ = module.reconcileScriptHubSubscriptionMetadata(subscription)
        }
        _ = module.repairSourceFormatFromUpdateSource()

        let preferredIconURL = module.customIconURL.flatMap(URL.init(string:)) ?? detectedIconURL
        module.iconURL = preferredIconURL?.absoluteString
        module.detectedSourceFormat = ModuleNamingPlanner.detectedFormat(
            for: module.sourceFormat,
            source: module.updateSourceURL
        )

        let contentChanged = module.contentHash != nextContentHash
        module.contentHash = nextContentHash
        module.lastUpdatedAt = updatedAt
        module.state = .current
        module.lastError = nil

        return ModuleSuccessfulConversionPlan(
            module: module,
            preferredIconURL: preferredIconURL,
            shouldRefreshIconCache: true,
            contentChanged: contentChanged,
            historyMessage: module.hasOverrideConflict ? "上游已更新，本地编辑需要确认" : "转换完成"
        )
    }

    static func unchangedCachedContentPlan(
        module: RelayModule,
        revisionSnapshot: SourceRevisionSnapshot
    ) -> ModuleUnchangedCachedContentPlan {
        var module = module
        module.sourceETag = revisionSnapshot.etag
        module.sourceLastModified = revisionSnapshot.lastModified
        module.sourceContentHash = revisionSnapshot.contentHash
        module.sourceCheckedAt = revisionSnapshot.checkedAt
        module.state = .current
        module.lastError = nil
        return ModuleUnchangedCachedContentPlan(
            module: module,
            historyMessage: "来源内容没有变化"
        )
    }
}
