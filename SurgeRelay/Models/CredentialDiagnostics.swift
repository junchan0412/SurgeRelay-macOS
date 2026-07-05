import Foundation

enum CredentialStorageStatus: String, Codable, Equatable, Sendable {
    case notChecked
    case keychain
    case notConfigured
    case legacyConfigurationFallback
    case memoryOnly
    case unavailable

    var title: String {
        switch self {
        case .notChecked: "尚未检查"
        case .keychain: "已保存到系统钥匙串"
        case .notConfigured: "未配置"
        case .legacyConfigurationFallback: "钥匙串不可用，暂用旧配置"
        case .memoryOnly: "钥匙串不可用，仅本次运行有效"
        case .unavailable: "钥匙串不可用"
        }
    }
}

enum KeychainAccessProbeState: String, Codable, Equatable, Sendable {
    case notChecked
    case checking
    case available
    case unavailable

    var title: String {
        switch self {
        case .notChecked: "尚未检查"
        case .checking: "正在检查"
        case .available: "可用"
        case .unavailable: "不可用"
        }
    }

    var systemImage: String {
        switch self {
        case .notChecked: "questionmark.circle"
        case .checking: "clock"
        case .available: "checkmark.circle.fill"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }
}

struct KeychainAccessProbeSnapshot: Codable, Equatable, Sendable {
    var state: KeychainAccessProbeState
    var message: String
    var statusCode: Int32?
    var recoverySuggestion: String
    var checkedAt: Date?

    static let notChecked = KeychainAccessProbeSnapshot(
        state: .notChecked,
        message: "尚未主动检查钥匙串读写权限。",
        statusCode: nil,
        recoverySuggestion: "",
        checkedAt: nil
    )

    static let checking = KeychainAccessProbeSnapshot(
        state: .checking,
        message: "正在写入、读取并清理临时诊断项。",
        statusCode: nil,
        recoverySuggestion: "",
        checkedAt: nil
    )

    static func current(
        service: String = KeychainStore.defaultService,
        checkedAt: Date = .now
    ) -> KeychainAccessProbeSnapshot {
        from(result: KeychainStore.probeAccess(service: service), checkedAt: checkedAt)
    }

    static func from(
        result: KeychainAccessProbeResult,
        checkedAt: Date
    ) -> KeychainAccessProbeSnapshot {
        KeychainAccessProbeSnapshot(
            state: result.isAvailable ? .available : .unavailable,
            message: result.message,
            statusCode: result.statusCode,
            recoverySuggestion: result.recoverySuggestion,
            checkedAt: checkedAt
        )
    }
}

struct CredentialDiagnosticSnapshot: Codable, Equatable, Sendable {
    var keychainService: String
    var keychainAccessState: KeychainAccessProbeState
    var keychainAccessStatus: String
    var keychainAccessMessage: String
    var keychainAccessStatusCode: Int32?
    var keychainAccessRecoverySuggestion: String
    var keychainAccessCheckedAt: Date?
    var githubTokenAccount: String
    var githubTokenStatus: String
    var webAccessTokenAccount: String
    var webAccessTokenStatus: String
    var note: String

    static func current(
        githubTokenStatus: CredentialStorageStatus,
        webAccessTokenStatus: CredentialStorageStatus,
        keychainAccessProbe: KeychainAccessProbeSnapshot = .notChecked
    ) -> CredentialDiagnosticSnapshot {
        CredentialDiagnosticSnapshot(
            keychainService: KeychainStore.defaultService,
            keychainAccessState: keychainAccessProbe.state,
            keychainAccessStatus: keychainAccessProbe.state.title,
            keychainAccessMessage: keychainAccessProbe.message,
            keychainAccessStatusCode: keychainAccessProbe.statusCode,
            keychainAccessRecoverySuggestion: keychainAccessProbe.recoverySuggestion,
            keychainAccessCheckedAt: keychainAccessProbe.checkedAt,
            githubTokenAccount: KeychainStore.githubTokenAccount,
            githubTokenStatus: githubTokenStatus.title,
            webAccessTokenAccount: KeychainStore.webAccessTokenAccount,
            webAccessTokenStatus: webAccessTokenStatus.title,
            note: "Surge Relay 只使用系统钥匙串保存 GitHub Token 和 Web 管理访问令牌；主动检查会创建一个临时诊断项并立即删除，诊断报告会导出错误码和修复建议，但不会导出令牌内容。"
        )
    }
}
