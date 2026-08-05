import Foundation

enum CredentialStorageStatus: String, Codable, Equatable, Sendable {
    case notChecked
    case encrypted
    case notConfigured
    case legacyConfigurationFallback
    case memoryOnly
    case unavailable

    var title: String {
        switch self {
        case .notChecked: "尚未检查"
        case .encrypted: "已保存到本地加密文件"
        case .notConfigured: "未配置"
        case .legacyConfigurationFallback: "本地加密存储不可用，暂用旧配置"
        case .memoryOnly: "本地加密存储不可用，仅本次运行有效"
        case .unavailable: "本地加密存储不可用"
        }
    }
}

enum LocalCredentialProbeState: String, Codable, Equatable, Sendable {
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

struct LocalCredentialProbeSnapshot: Codable, Equatable, Sendable {
    var state: LocalCredentialProbeState
    var message: String
    var recoverySuggestion: String
    var checkedAt: Date?

    static let notChecked = LocalCredentialProbeSnapshot(
        state: .notChecked,
        message: "尚未主动检查本地加密存储读写权限。",
        recoverySuggestion: "",
        checkedAt: nil
    )

    static let checking = LocalCredentialProbeSnapshot(
        state: .checking,
        message: "正在写入、读取并清理临时诊断项。",
        recoverySuggestion: "",
        checkedAt: nil
    )

    static func current(
        fileURL: URL = LocalCredentialStore.defaultFileURL,
        keyURL: URL = LocalCredentialStore.defaultKeyURL,
        checkedAt: Date = .now
    ) -> LocalCredentialProbeSnapshot {
        from(result: LocalCredentialStore.probeAccess(fileURL: fileURL, keyURL: keyURL), checkedAt: checkedAt)
    }

    static func from(
        result: LocalCredentialProbeResult,
        checkedAt: Date
    ) -> LocalCredentialProbeSnapshot {
        LocalCredentialProbeSnapshot(
            state: result.isAvailable ? .available : .unavailable,
            message: result.message,
            recoverySuggestion: result.recoverySuggestion,
            checkedAt: checkedAt
        )
    }
}

struct CredentialDiagnosticSnapshot: Codable, Equatable, Sendable {
    var storageLocation: String
    var probeState: LocalCredentialProbeState
    var probeStatus: String
    var probeMessage: String
    var probeRecoverySuggestion: String
    var probeCheckedAt: Date?
    var githubTokenAccount: String
    var githubTokenStatus: String
    var webAccessTokenAccount: String
    var webAccessTokenStatus: String
    var note: String

    static func current(
        githubTokenStatus: CredentialStorageStatus,
        webAccessTokenStatus: CredentialStorageStatus,
        credentialProbe: LocalCredentialProbeSnapshot = .notChecked
    ) -> CredentialDiagnosticSnapshot {
        CredentialDiagnosticSnapshot(
            storageLocation: LocalCredentialStore.defaultFileURL.path,
            probeState: credentialProbe.state,
            probeStatus: credentialProbe.state.title,
            probeMessage: credentialProbe.message,
            probeRecoverySuggestion: credentialProbe.recoverySuggestion,
            probeCheckedAt: credentialProbe.checkedAt,
            githubTokenAccount: LocalCredentialStore.githubTokenAccount,
            githubTokenStatus: githubTokenStatus.title,
            webAccessTokenAccount: LocalCredentialStore.webAccessTokenAccount,
            webAccessTokenStatus: webAccessTokenStatus.title,
            note: "Surge Relay 使用配置目录中的本地加密文件保存 GitHub Token 和 Web 管理访问令牌，不依赖系统钥匙串，无开发者账户签名也可正常保存；主动检查会写入并立即删除临时诊断项，诊断报告不会导出密钥或令牌内容。"
        )
    }
}
