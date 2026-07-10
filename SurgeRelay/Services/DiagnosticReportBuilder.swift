import Foundation

struct DiagnosticReportBuildRequest: Sendable {
    var generatedAt: Date = .now
    var appVersion: String
    var operatingSystem: String
    var settings: AppSettings
    var modules: [RelayModule]
    var upstreamState: ScriptHubUpstreamState
    var installation: InstallationDiagnosticSnapshot
    var credentials: CredentialDiagnosticSnapshot
    var localModuleRoot: LocalModuleRootDiagnosticSnapshot
    var webServerState: WebServerRuntimeState
    var webManagementURL: URL?
    var webManagementAccessModeTitle: String
    var webAccessTokenStorageStatus: CredentialStorageStatus
    var automaticPublishScheduledAt: Date?
    var automaticPublishRunsAt: Date?
    var latestGitHubPublish: GitHubPublishSnapshot?
    var workActivity: WorkActivity
    var statusMessage: String
    var workCancellationRequested: Bool
    var history: [UpdateHistoryEntry]
}

enum DiagnosticReportBuilder {
    static func data(for request: DiagnosticReportBuildRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report(for: request))
    }

    static func report(for request: DiagnosticReportBuildRequest) -> DiagnosticReport {
        DiagnosticReport(
            generatedAt: request.generatedAt,
            appVersion: request.appVersion,
            operatingSystem: request.operatingSystem,
            installation: request.installation,
            credentials: request.credentials,
            engineRevision: request.upstreamState.revision,
            storageMode: storageModeDescription(settings: request.settings),
            localModuleRoot: request.localModuleRoot,
            githubRepository: "\(request.settings.github.owner)/\(request.settings.github.repository)",
            webServerEnabled: request.settings.webServerEnabled,
            webServerState: request.webServerState.diagnosticValue,
            webServerPort: request.settings.webServerPort,
            webServerAllowRemoteAccess: request.settings.webServerAllowRemoteAccess,
            webServerAccessMode: request.webManagementAccessModeTitle,
            webManagementURL: request.webManagementURL?.absoluteString,
            webAccessTokenStorageStatus: request.webAccessTokenStorageStatus.title,
            automaticPublishScheduledAt: request.automaticPublishScheduledAt,
            automaticPublishRunsAt: request.automaticPublishRunsAt,
            latestGitHubPublish: request.latestGitHubPublish,
            activeWorkKind: request.workActivity.kind.rawValue,
            activeWorkTitle: request.workActivity.isActive ? request.workActivity.title : nil,
            activeWorkStatus: request.workActivity.isActive ? request.statusMessage : nil,
            activeWorkStartedAt: request.workActivity.startedAt,
            activeWorkBlocksUpdates: request.workActivity.blocksUpdates,
            activeWorkCanCancel: request.workActivity.canCancel,
            activeWorkCancellationRequested: request.workCancellationRequested,
            modules: request.modules.map(moduleSnapshot),
            history: request.history
        )
    }

    static func storageModeDescription(settings: AppSettings) -> String {
        switch (settings.publishToLocal, settings.publishToGitHub) {
        case (true, true): "Local + GitHub"
        case (true, false): "Local"
        case (false, true): "GitHub"
        case (false, false): "None"
        }
    }

    static func redactedSourceURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? value
    }

    private static func moduleSnapshot(_ module: RelayModule) -> DiagnosticModuleSnapshot {
        DiagnosticModuleSnapshot(
            id: module.id,
            name: module.name,
            sourceURL: redactedSourceURL(module.sourceURL),
            initialSourceURL: module.initialSourceURL.map(redactedSourceURL),
            updateSourceURL: redactedSourceURL(module.updateSourceURL),
            storageLocation: module.storageLocation.rawValue,
            storageLocationTitle: module.displayStorageLocationTitle,
            initialSourceTitle: module.initialSource.title,
            relationshipSummary: module.relationshipSummary,
            localStorageRelativePath: module.localStorageRelativePath,
            enabled: module.isEnabled,
            state: module.state.rawValue,
            lastUpdatedAt: module.lastUpdatedAt,
            sourceCheckedAt: module.sourceCheckedAt,
            lastError: module.lastError,
            hasOverrideConflict: module.hasOverrideConflict
        )
    }
}
