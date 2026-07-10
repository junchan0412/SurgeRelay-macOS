import Foundation
import XCTest
@testable import SurgeRelay

final class DiagnosticReportTests: XCTestCase {
    func testDiagnosticReportBuilderRedactsModuleSourceURLs() throws {
        var settings = AppSettings()
        settings.publishToLocal = true
        settings.publishToGitHub = true
        settings.github.owner = "someone"
        settings.github.repository = "relay"
        settings.webServerEnabled = true
        settings.webServerPort = 8787

        var upstreamState = ScriptHubUpstreamState()
        upstreamState.revision = "abcdef123456"
        let module = RelayModule(
            name: "Private Source",
            sourceURL: "https://user:pass@example.com/path/module.sgmodule?token=secret#fragment",
            outputFileName: "Private Source",
            publishesStandalone: true
        )
        let request = DiagnosticReportBuildRequest(
            generatedAt: Date(timeIntervalSince1970: 1_000),
            appVersion: "1.3.8",
            operatingSystem: "macOS Test",
            settings: settings,
            modules: [module],
            upstreamState: upstreamState,
            installation: InstallationDiagnosticSnapshot(
                appPath: "/Applications/Surge Relay.app",
                appVersion: "1.3.8",
                buildNumber: "57",
                bundleIdentifier: "com.allenmiao.SurgeRelay",
                runningFromApplications: true,
                signatureStatus: "固定证书签名",
                gatekeeperStatus: "已被 Gatekeeper 接受",
                quarantineStatus: "无隔离属性",
                recentCrashReportStatus: "最近 24 小时未发现崩溃报告",
                recentCrashReports: [],
                sparkleAutomaticChecksEnabled: true,
                sparkleFeedURL: nil,
                updateRecommendation: "App 内更新可用"
            ),
            credentials: CredentialDiagnosticSnapshot.current(
                githubTokenStatus: .keychain,
                webAccessTokenStatus: .memoryOnly,
                keychainAccessProbe: .notChecked
            ),
            localModuleRoot: LocalModuleRootDiagnosticSnapshot(
                path: "/Users/example/Surge",
                exists: true,
                isDirectory: true,
                isWritable: true,
                folderCount: 1,
                moduleFileCount: 1,
                status: "目录可用",
                error: nil
            ),
            webServerState: .running,
            webManagementURL: URL(string: "http://127.0.0.1:8787/"),
            webManagementAccessModeTitle: "仅本机",
            webAccessTokenStorageStatus: .memoryOnly,
            automaticPublishScheduledAt: nil,
            automaticPublishRunsAt: nil,
            latestGitHubPublish: nil,
            workActivity: WorkActivity(
                kind: .publishing,
                startedAt: Date(timeIntervalSince1970: 900),
                blocksUpdates: true,
                canCancel: false
            ),
            statusMessage: "正在提交 GitHub 发布",
            workCancellationRequested: true,
            history: []
        )

        let report = DiagnosticReportBuilder.report(for: request)
        let snapshot = try XCTUnwrap(report.modules.first)

        XCTAssertEqual(report.storageMode, "Local + GitHub")
        XCTAssertEqual(report.githubRepository, "someone/relay")
        XCTAssertEqual(report.engineRevision, "abcdef123456")
        XCTAssertEqual(report.webServerState, "running")
        XCTAssertEqual(report.webManagementURL, "http://127.0.0.1:8787/")
        XCTAssertEqual(report.webAccessTokenStorageStatus, "钥匙串不可用，仅本次运行有效")
        XCTAssertEqual(report.activeWorkKind, "publishing")
        XCTAssertEqual(report.activeWorkTitle, "GitHub 发布")
        XCTAssertEqual(report.activeWorkStatus, "正在提交 GitHub 发布")
        XCTAssertTrue(report.activeWorkCancellationRequested)
        XCTAssertEqual(snapshot.sourceURL, "https://example.com/path/module.sgmodule")
        XCTAssertNil(snapshot.initialSourceURL)
        XCTAssertEqual(snapshot.updateSourceURL, "https://example.com/path/module.sgmodule")
        XCTAssertEqual(snapshot.initialSourceTitle, "自写模块")

        let json = try XCTUnwrap(String(data: DiagnosticReportBuilder.data(for: request), encoding: .utf8))
        XCTAssertFalse(json.contains("token=secret"))
        XCTAssertFalse(json.contains("user:pass"))
        XCTAssertFalse(json.contains("fragment"))
    }
}
