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
            keychainAccessProbe: keychainAccessProbe
        )
    }

    func refreshKeychainAccessProbe() {
        keychainAccessProbe = .checking
        let tracksActivity = !workActivity.blocksUpdates
        if tracksActivity {
            beginWork(.checkingKeychain, blocksUpdates: false)
        }
        Task { @MainActor in
            let snapshot = await Task.detached(priority: .utility) {
                KeychainAccessProbeSnapshot.current()
            }.value
            keychainAccessProbe = snapshot
            if tracksActivity {
                endWork(.checkingKeychain)
            }
            statusMessage = snapshot.state == .available
                ? "钥匙串读写检查通过"
                : "钥匙串读写检查失败"
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
