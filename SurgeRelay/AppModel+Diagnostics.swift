import Foundation

@MainActor
extension AppModel {
    func installationDiagnostics() -> InstallationDiagnosticSnapshot {
        InstallationDiagnosticSnapshot.current()
    }

    func credentialDiagnostics() -> CredentialDiagnosticSnapshot {
        CredentialDiagnosticSnapshot.current(
            githubTokenStatus: githubTokenStorageStatus,
            webAccessTokenStatus: webAccessTokenStorageStatus,
            credentialProbe: credentialProbe
        )
    }

    func refreshCredentialProbe() {
        credentialProbe = .checking
        let tracksActivity = !workActivity.blocksUpdates
        if tracksActivity {
            beginWork(.checkingLocalCredentials, blocksUpdates: false)
        }
        Task { @MainActor in
            let snapshot = await Task.detached(priority: .utility) {
                LocalCredentialProbeSnapshot.current()
            }.value
            credentialProbe = snapshot
            if tracksActivity {
                endWork(.checkingLocalCredentials)
            }
            statusMessage = snapshot.state == .available
                ? "本地加密读写检查通过"
                : "本地加密读写检查失败"
        }
    }

    func localModuleRootDiagnostics() -> LocalModuleRootDiagnosticSnapshot {
        LocalModuleRootDiagnosticSnapshot.current(path: settings.localModuleDirectory)
    }

    func diagnosticsData() throws -> Data {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        return try DiagnosticReportBuilder.data(for: DiagnosticReportBuildRequest(
            appVersion: version,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            settings: settings,
            modules: modules,
            upstreamState: upstreamState,
            installation: installationDiagnostics(),
            credentials: credentialDiagnostics(),
            localModuleRoot: localModuleRootDiagnostics(),
            webServerState: webServerState,
            webManagementURL: webManagementDisplayURL,
            webManagementAccessModeTitle: webManagementAccessModeTitle,
            webAccessTokenStorageStatus: webAccessTokenStorageStatus,
            automaticPublishScheduledAt: automaticPublishScheduledAt,
            automaticPublishRunsAt: automaticPublishRunsAt,
            latestGitHubPublish: latestGitHubPublish,
            workActivity: workActivity,
            statusMessage: statusMessage,
            workCancellationRequested: workCancellationRequested,
            history: updateHistory
        ))
    }
}
