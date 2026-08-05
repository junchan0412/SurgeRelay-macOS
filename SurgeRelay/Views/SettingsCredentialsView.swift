import AppKit
import SwiftUI

struct SettingsCredentialsView: View {
    @Environment(AppModel.self) private var model
    @State private var isTesting = false
    @State private var connectionResult: ConnectionResult?

    private enum ConnectionResult {
        case success(String)
        case failure(String)

        var message: String {
            switch self {
            case let .success(text), let .failure(text): text
            }
        }

        var isError: Bool {
            if case .failure = self { return true }
            return false
        }
    }

    var body: some View {
        SettingsForm {
            githubTokenSection
            webAccessTokenSection
            SettingsSection("本地加密存储状态") {
                localCredentialDiagnosticsContent
            }
        }
        .onAppear {
            if !AppRuntimeOptions.isUIQAMode {
                model.ensureGitHubTokenLoaded()
                model.ensureWebAccessTokenForEditing()
            }
        }
    }

    private var githubTokenSection: some View {
        SettingsSection("GitHub Token") {
            SettingsSecureFieldRow("Token", icon: "key.fill", text: Binding(
                get: { model.githubToken },
                set: { model.githubToken = $0 }
            ))
            SettingsInfoRow("保存状态", icon: githubTokenStorageImage) {
                Label(model.githubTokenStorageStatus.title, systemImage: githubTokenStorageImage)
                    .foregroundStyle(githubTokenStorageColor)
            }
            SettingsInfoRow("权限范围", icon: "checkmark.shield") {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Fine-grained token：Contents 读写、Metadata 只读。", systemImage: "checkmark.shield")
                    Label("Classic token：公开仓库 public_repo；私有仓库 repo。", systemImage: "lock")
                    Label("不需要 admin、delete_repo、workflow 或组织管理权限。", systemImage: "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            SettingsControlRow("操作", icon: "ellipsis.circle") {
                HStack(spacing: 8) {
                    Link("创建 Token", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                    Button("保存到本地", systemImage: "lock.fill") { model.saveGitHubToken() }
                    Button("测试连接", systemImage: "network") { testGitHubConnection() }
                        .disabled(model.githubToken.isEmpty || !model.settings.github.isConfigured || isTesting)
                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            if !model.settings.github.isConfigured {
                Label("测试连接前请先在“发布”中填写 GitHub 仓库信息。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let result = connectionResult {
                Label(result.message, systemImage: result.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(result.isError ? .red : .green)
                    .textSelection(.enabled)
            }
        }
    }

    private var webAccessTokenSection: some View {
        SettingsSection("Web 管理令牌") {
            SettingsSecureFieldRow("令牌", icon: "network.badge.shield.half.filled", text: Binding(
                get: { model.webAccessToken },
                set: { model.webAccessToken = $0 }
            ))
            SettingsInfoRow("保存状态", icon: webAccessTokenStorageImage) {
                Label(model.webAccessTokenStorageStatus.title, systemImage: webAccessTokenStorageImage)
                    .foregroundStyle(webAccessTokenStorageColor)
            }
            SettingsInfoRow("用途", icon: "network.badge.shield.half.filled") {
                Text("访问 Web 管理页面时使用；可自己填写，也可生成随机令牌。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            SettingsControlRow("操作", icon: "ellipsis.circle") {
                HStack(spacing: 8) {
                    Button("保存到本地", systemImage: "lock.fill") { model.saveWebAccessToken() }
                    Button("生成新令牌", systemImage: "arrow.triangle.2.circlepath") { model.resetWebAccessToken() }
                    Button("拷贝令牌", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.webAccessToken, forType: .string)
                    }
                    .disabled(model.webAccessToken.isEmpty)
                }
            }
        }
    }

    private var localCredentialDiagnosticsContent: some View {
        let credentials = model.credentialDiagnostics()
        return Group {
            SettingsCopyableInfoRow(
                title: "存储位置",
                value: credentials.storageLocation,
                icon: "lock.fill",
                monospaced: true,
                copyValue: credentials.storageLocation
            )
            SettingsInfoRow("读写检查", icon: "checkmark.shield") {
                VStack(alignment: .leading, spacing: 2) {
                    Label(credentials.probeStatus, systemImage: credentials.probeState.systemImage)
                        .foregroundStyle(credentialProbeColor(credentials.probeState))
                    if let checkedAt = credentials.probeCheckedAt {
                        Text(checkedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Text(credentials.probeMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if !credentials.probeRecoverySuggestion.isEmpty {
                Label(credentials.probeRecoverySuggestion, systemImage: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            credentialLabel(
                "GitHub Token",
                account: credentials.githubTokenAccount,
                status: credentials.githubTokenStatus
            )
            credentialLabel(
                "Web 管理令牌",
                account: credentials.webAccessTokenAccount,
                status: credentials.webAccessTokenStatus
            )
            Label(credentials.note, systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("重新检查", systemImage: "arrow.clockwise") {
                model.refreshCredentialProbe()
            }
            .disabled(credentials.probeState == .checking)
        }
    }

    private var githubTokenStorageImage: String {
        switch model.githubTokenStorageStatus {
        case .encrypted: "checkmark.circle.fill"
        case .notChecked, .notConfigured: "questionmark.circle"
        case .legacyConfigurationFallback, .memoryOnly, .unavailable: "exclamationmark.triangle.fill"
        }
    }

    private var githubTokenStorageColor: Color {
        switch model.githubTokenStorageStatus {
        case .encrypted: .green
        case .notChecked, .notConfigured: .secondary
        case .legacyConfigurationFallback, .memoryOnly, .unavailable: .orange
        }
    }

    private var webAccessTokenStorageImage: String {
        switch model.webAccessTokenStorageStatus {
        case .encrypted: "lock.fill"
        case .notChecked, .notConfigured: "questionmark.circle"
        case .legacyConfigurationFallback, .memoryOnly, .unavailable: "exclamationmark.triangle.fill"
        }
    }

    private var webAccessTokenStorageColor: Color {
        switch model.webAccessTokenStorageStatus {
        case .encrypted: .green
        case .notChecked, .notConfigured: .secondary
        case .legacyConfigurationFallback, .memoryOnly, .unavailable: .orange
        }
    }

    private func credentialProbeColor(_ state: LocalCredentialProbeState) -> Color {
        switch state {
        case .available: .green
        case .unavailable: .orange
        case .checking, .notChecked: .secondary
        }
    }

    private func credentialLabel(_ title: String, account: String, status: String) -> some View {
        let storedLocally = status == CredentialStorageStatus.encrypted.title
        let neutral = status == CredentialStorageStatus.notConfigured.title ||
            status == CredentialStorageStatus.notChecked.title
        return SettingsInfoRow(title, icon: storedLocally ? "checkmark.circle.fill" : (neutral ? "questionmark.circle" : "exclamationmark.triangle.fill")) {
            VStack(alignment: .leading, spacing: 2) {
                Label(
                    status,
                    systemImage: storedLocally
                        ? "checkmark.circle.fill"
                        : (neutral ? "questionmark.circle" : "exclamationmark.triangle.fill")
                )
                .foregroundStyle(storedLocally ? .green : (neutral ? .secondary : .orange))
                Text(account)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
    }

    private func testGitHubConnection() {
        Task {
            isTesting = true
            connectionResult = nil
            model.presentedError = nil
            await model.testGitHub(showProgress: false)
            isTesting = false
            if let error = model.presentedError {
                connectionResult = .failure(error)
                model.presentedError = nil
            } else {
                connectionResult = .success(model.statusMessage)
            }
        }
    }
}
