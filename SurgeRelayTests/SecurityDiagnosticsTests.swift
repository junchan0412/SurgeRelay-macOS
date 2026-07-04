import Security
import XCTest
@testable import SurgeRelay

final class SecurityDiagnosticsTests: XCTestCase {
    func testKeychainStoreRoundTripsPasswordWithCustomService() throws {
        let service = "com.allenmiao.SurgeRelayTests.\(UUID().uuidString)"
        let account = "github-token"
        defer { try? KeychainStore.deletePassword(account: account, service: service) }

        do {
            XCTAssertNil(try KeychainStore.readPassword(account: account, service: service))
            try KeychainStore.savePassword("ghp_first", account: account, service: service)
            XCTAssertEqual(try KeychainStore.readPassword(account: account, service: service), "ghp_first")
            try KeychainStore.savePassword("ghp_second", account: account, service: service)
            XCTAssertEqual(try KeychainStore.readPassword(account: account, service: service), "ghp_second")
            try KeychainStore.deletePassword(account: account, service: service)
            XCTAssertNil(try KeychainStore.readPassword(account: account, service: service))
        } catch let error as KeychainStoreError
            where [errSecNotAvailable, errSecInteractionNotAllowed, errSecAuthFailed].contains(error.status) {
            throw XCTSkip("Keychain is unavailable in this test environment: \(error.localizedDescription)")
        }
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

    func testCredentialDiagnosticsDescribeKeychainAccountsWithoutSecrets() {
        let checkedAt = Date(timeIntervalSince1970: 1_800)
        let diagnostics = CredentialDiagnosticSnapshot.current(
            githubTokenStatus: .keychain,
            webAccessTokenStatus: .memoryOnly,
            keychainAccessProbe: .from(
                result: KeychainAccessProbeResult(isAvailable: true, message: "钥匙串读写正常。"),
                checkedAt: checkedAt
            )
        )
        XCTAssertEqual(diagnostics.keychainService, KeychainStore.defaultService)
        XCTAssertEqual(diagnostics.keychainAccessState, .available)
        XCTAssertEqual(diagnostics.keychainAccessStatus, "可用")
        XCTAssertEqual(diagnostics.keychainAccessMessage, "钥匙串读写正常。")
        XCTAssertNil(diagnostics.keychainAccessStatusCode)
        XCTAssertEqual(diagnostics.keychainAccessRecoverySuggestion, "")
        XCTAssertEqual(diagnostics.keychainAccessCheckedAt, checkedAt)
        XCTAssertEqual(diagnostics.githubTokenAccount, KeychainStore.githubTokenAccount)
        XCTAssertEqual(diagnostics.webAccessTokenAccount, KeychainStore.webAccessTokenAccount)
        XCTAssertFalse(diagnostics.note.contains("ghp_"))
        XCTAssertFalse(diagnostics.note.contains("Bearer"))
    }

    func testCredentialDiagnosticsCanRepresentUncheckedStorage() {
        let diagnostics = CredentialDiagnosticSnapshot.current(
            githubTokenStatus: .notChecked,
            webAccessTokenStatus: .notChecked,
            keychainAccessProbe: .notChecked
        )

        XCTAssertEqual(diagnostics.githubTokenStatus, "尚未检查")
        XCTAssertEqual(diagnostics.webAccessTokenStatus, "尚未检查")
        XCTAssertEqual(diagnostics.keychainAccessStatus, "尚未检查")
    }

    func testKeychainProbeSnapshotDescribesUnavailableAccess() {
        let checkedAt = Date(timeIntervalSince1970: 2_400)
        let snapshot = KeychainAccessProbeSnapshot.from(
            result: KeychainAccessProbeResult(
                isAvailable: false,
                message: "钥匙串保存失败：User interaction is not allowed.",
                statusCode: errSecInteractionNotAllowed,
                recoverySuggestion: "请解锁登录钥匙串。"
            ),
            checkedAt: checkedAt
        )

        XCTAssertEqual(snapshot.state, .unavailable)
        XCTAssertEqual(snapshot.state.title, "不可用")
        XCTAssertEqual(snapshot.message, "钥匙串保存失败：User interaction is not allowed.")
        XCTAssertEqual(snapshot.statusCode, errSecInteractionNotAllowed)
        XCTAssertEqual(snapshot.recoverySuggestion, "请解锁登录钥匙串。")
        XCTAssertEqual(snapshot.checkedAt, checkedAt)
    }

    func testKeychainStoreErrorProvidesActionableRecoverySuggestion() {
        let interactionError = KeychainStoreError(operation: "保存", status: errSecInteractionNotAllowed)
        XCTAssertEqual(Int32(interactionError.status), errSecInteractionNotAllowed)
        XCTAssertTrue(interactionError.localizedDescription.contains("钥匙串保存失败"))
        XCTAssertTrue(interactionError.recoverySuggestion?.contains("登录") == true)
        XCTAssertTrue(interactionError.recoverySuggestion?.contains("允许") == true)

        let entitlementError = KeychainStoreError(operation: "读取", status: errSecMissingEntitlement)
        XCTAssertTrue(entitlementError.recoverySuggestion?.contains("pkg") == true)
        XCTAssertTrue(entitlementError.recoverySuggestion?.contains("重新保存 Token") == true)
    }
}
