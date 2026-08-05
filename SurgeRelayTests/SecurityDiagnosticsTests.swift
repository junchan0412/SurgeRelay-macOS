import XCTest
@testable import SurgeRelay

final class SecurityDiagnosticsTests: XCTestCase {
    func testLocalCredentialStoreRoundTripsPasswordInTemporaryDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appending(path: "credentials.encrypted")
        let keyURL = root.appending(path: "credentials.key")
        let account = "github-token"

        XCTAssertNil(try LocalCredentialStore.readPassword(account: account, fileURL: fileURL, keyURL: keyURL))
        try LocalCredentialStore.savePassword("ghp_first", account: account, fileURL: fileURL, keyURL: keyURL)
        XCTAssertEqual(
            try LocalCredentialStore.readPassword(account: account, fileURL: fileURL, keyURL: keyURL),
            "ghp_first"
        )
        try LocalCredentialStore.savePassword("ghp_second", account: account, fileURL: fileURL, keyURL: keyURL)
        XCTAssertEqual(
            try LocalCredentialStore.readPassword(account: account, fileURL: fileURL, keyURL: keyURL),
            "ghp_second"
        )
        try LocalCredentialStore.deletePassword(account: account, fileURL: fileURL, keyURL: keyURL)
        XCTAssertNil(try LocalCredentialStore.readPassword(account: account, fileURL: fileURL, keyURL: keyURL))
    }

    func testLocalCredentialStoreProbeRoundTripsTemporaryDiagnosticEntry() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appending(path: "credentials.encrypted")
        let keyURL = root.appending(path: "credentials.key")

        let result = LocalCredentialStore.probeAccess(fileURL: fileURL, keyURL: keyURL)

        XCTAssertTrue(result.isAvailable)
        XCTAssertTrue(result.message.contains("正常"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testInstallationDiagnosticsClassifiesAdHocGatekeeperAndQuarantine() {
        let signature = InstallationDiagnosticSnapshot.signatureSummary(from: .init(
            status: 0,
            output: "Signature=adhoc\nTeamIdentifier=not set\n"
        ))
        XCTAssertEqual(signature, "ad-hoc 签名，未使用 Developer ID")

        let selfSigned = InstallationDiagnosticSnapshot.signatureSummary(from: .init(
            status: 0,
            output: "Authority=Surge Relay Self-Signed Code Signing\nTeamIdentifier=not set\n"
        ))
        XCTAssertEqual(selfSigned, "固定证书签名（Surge Relay Self-Signed Code Signing）")

        let gatekeeper = InstallationDiagnosticSnapshot.gatekeeperSummary(from: .init(
            status: 1,
            output: "Surge Relay.app: rejected\n"
        ))
        XCTAssertEqual(gatekeeper, "会被 Gatekeeper 拦截，首次安装可能需要手动信任")

        let quarantine = InstallationDiagnosticSnapshot.quarantineSummary(from: .init(
            status: 0,
            output: "0081;687...;Safari;\n"
        ))
        XCTAssertEqual(quarantine, "存在隔离属性，首次打开可能被拦截")
    }

    func testInstallationDiagnosticsListsRecentCrashReports() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SurgeRelayCrashReports-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recent = root.appending(path: "Surge Relay-2026-07-02-120000.ips")
        let old = root.appending(path: "Surge Relay-2026-06-30-120000.crash")
        let otherApp = root.appending(path: "Other App-2026-07-02-120000.ips")
        try Data("recent".utf8).write(to: recent)
        try Data("old".utf8).write(to: old)
        try Data("other".utf8).write(to: otherApp)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: recent.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 500)],
            ofItemAtPath: old.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_100)],
            ofItemAtPath: otherApp.path
        )

        let reports = InstallationDiagnosticSnapshot.recentCrashReports(
            appName: "Surge Relay",
            diagnosticDirectory: root,
            since: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(reports.map(\.fileName), [recent.lastPathComponent])
        XCTAssertEqual(
            InstallationDiagnosticSnapshot.crashReportStatus(from: reports),
            "最近 24 小时发现 1 个崩溃报告"
        )
    }

    func testCredentialDiagnosticsDescribeLocalEncryptedAccountsWithoutSecrets() {
        let checkedAt = Date(timeIntervalSince1970: 1_800)
        let diagnostics = CredentialDiagnosticSnapshot.current(
            githubTokenStatus: .encrypted,
            webAccessTokenStatus: .memoryOnly,
            credentialProbe: .from(
                result: LocalCredentialProbeResult(isAvailable: true, message: "本地加密读写正常。"),
                checkedAt: checkedAt
            )
        )
        XCTAssertEqual(diagnostics.storageLocation, LocalCredentialStore.defaultFileURL.path)
        XCTAssertEqual(diagnostics.probeState, .available)
        XCTAssertEqual(diagnostics.probeStatus, "可用")
        XCTAssertEqual(diagnostics.probeMessage, "本地加密读写正常。")
        XCTAssertEqual(diagnostics.probeRecoverySuggestion, "")
        XCTAssertEqual(diagnostics.probeCheckedAt, checkedAt)
        XCTAssertEqual(diagnostics.githubTokenAccount, LocalCredentialStore.githubTokenAccount)
        XCTAssertEqual(diagnostics.webAccessTokenAccount, LocalCredentialStore.webAccessTokenAccount)
        XCTAssertFalse(diagnostics.note.contains("ghp_"))
        XCTAssertFalse(diagnostics.note.contains("Bearer"))
    }

    func testCredentialDiagnosticsCanRepresentUncheckedStorage() {
        let diagnostics = CredentialDiagnosticSnapshot.current(
            githubTokenStatus: .notChecked,
            webAccessTokenStatus: .notChecked,
            credentialProbe: .notChecked
        )

        XCTAssertEqual(diagnostics.githubTokenStatus, "尚未检查")
        XCTAssertEqual(diagnostics.webAccessTokenStatus, "尚未检查")
        XCTAssertEqual(diagnostics.probeStatus, "尚未检查")
    }

    func testLocalCredentialProbeSnapshotDescribesUnavailableAccess() {
        let checkedAt = Date(timeIntervalSince1970: 2_400)
        let snapshot = LocalCredentialProbeSnapshot.from(
            result: LocalCredentialProbeResult(
                isAvailable: false,
                message: "本地加密存储读取失败。",
                recoverySuggestion: "请检查配置目录读写权限。"
            ),
            checkedAt: checkedAt
        )

        XCTAssertEqual(snapshot.state, .unavailable)
        XCTAssertEqual(snapshot.state.title, "不可用")
        XCTAssertEqual(snapshot.message, "本地加密存储读取失败。")
        XCTAssertEqual(snapshot.recoverySuggestion, "请检查配置目录读写权限。")
        XCTAssertEqual(snapshot.checkedAt, checkedAt)
    }

    func testLocalCredentialStoreErrorProvidesActionableRecoverySuggestion() {
        let error = LocalCredentialStoreError(operation: "保存", detail: "加密失败。")
        XCTAssertTrue(error.localizedDescription.contains("本地加密存储保存失败"))
        XCTAssertTrue(error.recoverySuggestion?.contains("凭据") == true)
        XCTAssertTrue(error.recoverySuggestion?.contains("重新保存 Token") == true)
    }
}
