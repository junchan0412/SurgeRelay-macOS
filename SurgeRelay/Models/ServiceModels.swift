import Foundation

struct ConversionResult: Sendable {
    var content: String
    var requestURL: URL
    var assets: [GeneratedAsset] = []
}

struct GeneratedAsset: Sendable {
    var relativePath: String
    var data: Data
}

struct PublishFile: Sendable {
    var name: String
    var data: Data
}

struct PublishReport: Sendable {
    var publishedFiles: [String]
    var deletedFiles: [String] = []
    var commitSHA: String? = nil

    var changedFileCount: Int {
        publishedFiles.count + deletedFiles.count
    }
}

enum UpdateHistoryOutcome: String, Codable, Sendable {
    case updated
    case unchanged
    case cachedAfterFailure
    case failed
    case published

    var title: String {
        switch self {
        case .updated: "已更新"
        case .unchanged: "没有变化"
        case .cachedAfterFailure: "沿用缓存"
        case .failed: "失败"
        case .published: "已发布"
        }
    }
}

struct UpdateHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var date = Date.now
    var moduleID: UUID?
    var moduleName: String
    var outcome: UpdateHistoryOutcome
    var duration: TimeInterval
    var message: String
    var usedCache = false
    var contentChanged = false
}

struct DiagnosticModuleSnapshot: Codable, Sendable {
    var id: UUID
    var name: String
    var sourceURL: String
    var enabled: Bool
    var state: String
    var lastUpdatedAt: Date?
    var sourceCheckedAt: Date?
    var lastError: String?
    var hasOverrideConflict: Bool
}

struct DiagnosticReport: Codable, Sendable {
    var generatedAt: Date
    var appVersion: String
    var operatingSystem: String
    var installation: InstallationDiagnosticSnapshot
    var credentials: CredentialDiagnosticSnapshot
    var engineRevision: String?
    var storageMode: String
    var githubRepository: String
    var webServerEnabled: Bool
    var webServerPort: Int
    var webServerAllowRemoteAccess: Bool
    var modules: [DiagnosticModuleSnapshot]
    var history: [UpdateHistoryEntry]
}

struct InstallationDiagnosticSnapshot: Codable, Equatable, Sendable {
    struct CommandResult: Equatable, Sendable {
        var status: Int32
        var output: String
    }

    var appPath: String
    var appVersion: String
    var buildNumber: String
    var bundleIdentifier: String
    var runningFromApplications: Bool
    var signatureStatus: String
    var gatekeeperStatus: String
    var quarantineStatus: String
    var sparkleAutomaticChecksEnabled: Bool
    var sparkleFeedURL: String?
    var updateRecommendation: String

    static func current(
        bundle: Bundle = .main,
        runCommand: @Sendable (String, [String]) -> CommandResult = runSystemCommand
    ) -> InstallationDiagnosticSnapshot {
        let bundleURL = bundle.bundleURL.standardizedFileURL
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "-"
        let build = info["CFBundleVersion"] as? String ?? "-"
        let identifier = bundle.bundleIdentifier ?? "-"
        let automaticChecks = info["SUEnableAutomaticChecks"] as? Bool ?? false
        let feedURL = info["SUFeedURL"] as? String

        let codesign = runCommand("/usr/bin/codesign", ["-dvvv", "--entitlements", ":-", bundleURL.path])
        let spctl = runCommand("/usr/sbin/spctl", ["-a", "-vv", bundleURL.path])
        let xattr = runCommand("/usr/bin/xattr", ["-p", "com.apple.quarantine", bundleURL.path])

        return InstallationDiagnosticSnapshot(
            appPath: bundleURL.path,
            appVersion: version,
            buildNumber: build,
            bundleIdentifier: identifier,
            runningFromApplications: bundleURL.path.hasPrefix("/Applications/"),
            signatureStatus: signatureSummary(from: codesign),
            gatekeeperStatus: gatekeeperSummary(from: spctl),
            quarantineStatus: quarantineSummary(from: xattr),
            sparkleAutomaticChecksEnabled: automaticChecks,
            sparkleFeedURL: feedURL,
            updateRecommendation: updateRecommendation(automaticChecksEnabled: automaticChecks)
        )
    }

    static func signatureSummary(from result: CommandResult) -> String {
        guard result.status == 0 else { return "无法读取签名信息" }
        if result.output.contains("Signature=adhoc") { return "ad-hoc 签名，未使用 Developer ID" }
        if let team = firstCapture(in: result.output, pattern: #"TeamIdentifier=([^\n]+)"#),
           team != "not set" {
            return "Developer ID 或团队签名（Team \(team)）"
        }
        return "已签名"
    }

    static func gatekeeperSummary(from result: CommandResult) -> String {
        let lowercased = result.output.lowercased()
        if lowercased.contains("accepted") { return "已被 Gatekeeper 接受" }
        if lowercased.contains("rejected") { return "会被 Gatekeeper 拦截，首次安装可能需要手动信任" }
        return result.status == 0 ? "Gatekeeper 状态未知" : "无法完成 Gatekeeper 评估"
    }

    static func quarantineSummary(from result: CommandResult) -> String {
        result.status == 0 && !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "存在隔离属性，首次打开可能被拦截"
            : "未检测到隔离属性"
    }

    static func updateRecommendation(automaticChecksEnabled: Bool) -> String {
        automaticChecksEnabled
            ? "App 内自动检查更新已开启；如果 Sparkle appcast 未同步最新 Release，请优先使用 GitHub Release 中的 pkg。"
            : "App 内自动检查更新已关闭；当前推荐使用 GitHub Release 中的 pkg 更新，安装器会自动清除隔离属性。"
    }

    private static func runSystemCommand(_ executable: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return CommandResult(status: process.terminationStatus, output: output)
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }
    }

    private static func firstCapture(in value: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
}

enum CredentialStorageStatus: String, Codable, Equatable, Sendable {
    case keychain
    case notConfigured
    case legacyConfigurationFallback
    case memoryOnly
    case unavailable

    var title: String {
        switch self {
        case .keychain: "已保存到系统钥匙串"
        case .notConfigured: "未配置"
        case .legacyConfigurationFallback: "钥匙串不可用，暂用旧配置"
        case .memoryOnly: "钥匙串不可用，仅本次运行有效"
        case .unavailable: "钥匙串不可用"
        }
    }
}

struct CredentialDiagnosticSnapshot: Codable, Equatable, Sendable {
    var keychainService: String
    var githubTokenAccount: String
    var githubTokenStatus: String
    var webAccessTokenAccount: String
    var webAccessTokenStatus: String
    var note: String

    static func current(
        githubTokenStatus: CredentialStorageStatus,
        webAccessTokenStatus: CredentialStorageStatus
    ) -> CredentialDiagnosticSnapshot {
        CredentialDiagnosticSnapshot(
            keychainService: KeychainStore.defaultService,
            githubTokenAccount: KeychainStore.githubTokenAccount,
            githubTokenStatus: githubTokenStatus.title,
            webAccessTokenAccount: KeychainStore.webAccessTokenAccount,
            webAccessTokenStatus: webAccessTokenStatus.title,
            note: "Surge Relay 只使用系统钥匙串保存 GitHub Token 和 Web 管理访问令牌，诊断报告不会导出令牌内容。"
        )
    }
}

struct SourceRevisionSnapshot: Sendable {
    var etag: String?
    var lastModified: String?
    var contentHash: String
    var checkedAt: Date
}

enum SourceRevisionResult: Sendable {
    case unchanged(SourceRevisionSnapshot)
    case changed(SourceRevisionSnapshot)
}

struct UpstreamUpdateResult: Sendable {
    var revision: String
    var changed: Bool
    var scripts: [String: Data]
}

enum RelayError: LocalizedError, Sendable {
    case invalidSourceURL
    case invalidServiceURL
    case duplicateSourceURL
    case invalidOutput(String)
    case httpFailure(status: Int, message: String)
    case githubNotConfigured
    case githubTokenMissing
    case noFilesToPublish

    var errorDescription: String? {
        switch self {
        case .invalidSourceURL: "来源地址无效。"
        case .invalidServiceURL: "Script-Hub 服务地址无效。"
        case .duplicateSourceURL: "该模块已经添加，不能重复添加。"
        case .invalidOutput(let message): "转换结果无效：\(message)"
        case .httpFailure(let status, let message): "网络请求失败（\(status)）：\(message)"
        case .githubNotConfigured: "请先填写 GitHub 仓库信息。"
        case .githubTokenMissing: "请先保存 GitHub Token。"
        case .noFilesToPublish: "没有可发布的模块文件。"
        }
    }
}
