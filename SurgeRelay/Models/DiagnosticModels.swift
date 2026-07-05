import Foundation

struct DiagnosticModuleSnapshot: Codable, Sendable {
    var id: UUID
    var name: String
    var sourceURL: String
    var effectiveOriginalSourceURL: String
    var storageLocation: String
    var storageLocationTitle: String
    var sourceOriginTitle: String
    var relationshipSummary: String
    var localStorageRelativePath: String?
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
    var localModuleRoot: LocalModuleRootDiagnosticSnapshot
    var githubRepository: String
    var webServerEnabled: Bool
    var webServerState: String
    var webServerPort: Int
    var webServerAllowRemoteAccess: Bool
    var webServerAccessMode: String
    var webManagementURL: String?
    var webAccessTokenStorageStatus: String
    var automaticPublishScheduledAt: Date?
    var automaticPublishRunsAt: Date?
    var latestGitHubPublish: GitHubPublishSnapshot?
    var activeWorkKind: String
    var activeWorkTitle: String?
    var activeWorkStatus: String?
    var activeWorkStartedAt: Date?
    var activeWorkBlocksUpdates: Bool
    var activeWorkCanCancel: Bool
    var activeWorkCancellationRequested: Bool
    var modules: [DiagnosticModuleSnapshot]
    var history: [UpdateHistoryEntry]
}

struct LocalModuleRootDiagnosticSnapshot: Codable, Equatable, Sendable {
    var path: String
    var exists: Bool
    var isDirectory: Bool
    var isWritable: Bool
    var folderCount: Int
    var moduleFileCount: Int
    var status: String
    var error: String?

    static func current(path rawPath: String, fileManager: FileManager = .default) -> LocalModuleRootDiagnosticSnapshot {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return LocalModuleRootDiagnosticSnapshot(
                path: "",
                exists: false,
                isDirectory: false,
                isWritable: false,
                folderCount: 0,
                moduleFileCount: 0,
                status: "未设置本地模块根目录",
                error: nil
            )
        }

        let root = URL(filePath: trimmed, directoryHint: .isDirectory).standardizedFileURL
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory)
        guard exists else {
            return LocalModuleRootDiagnosticSnapshot(
                path: root.path,
                exists: false,
                isDirectory: false,
                isWritable: false,
                folderCount: 0,
                moduleFileCount: 0,
                status: "目录不存在",
                error: nil
            )
        }
        guard isDirectory.boolValue else {
            return LocalModuleRootDiagnosticSnapshot(
                path: root.path,
                exists: true,
                isDirectory: false,
                isWritable: false,
                folderCount: 0,
                moduleFileCount: 0,
                status: "路径不是文件夹",
                error: nil
            )
        }

        let isWritable = fileManager.isWritableFile(atPath: root.path)
        var folderCount = 0
        var moduleFileCount = 0
        var scanError: String?
        if let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator {
                do {
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey])
                    if values.isPackage == true { continue }
                    if values.isDirectory == true {
                        folderCount += 1
                    } else if values.isRegularFile == true, url.pathExtension.lowercased() == "sgmodule" {
                        moduleFileCount += 1
                    }
                } catch {
                    scanError = error.localizedDescription
                    break
                }
            }
        } else {
            scanError = "无法枚举目录内容"
        }

        let status = if let scanError {
            "目录可访问，但扫描不完整：\(scanError)"
        } else if !isWritable {
            "目录存在，但当前不可写"
        } else {
            "目录可用"
        }
        return LocalModuleRootDiagnosticSnapshot(
            path: root.path,
            exists: true,
            isDirectory: true,
            isWritable: isWritable,
            folderCount: folderCount,
            moduleFileCount: moduleFileCount,
            status: status,
            error: scanError
        )
    }
}

struct InstallationDiagnosticSnapshot: Codable, Equatable, Sendable {
    struct CommandResult: Equatable, Sendable {
        var status: Int32
        var output: String
    }

    struct RecentCrashReport: Codable, Equatable, Identifiable, Sendable {
        var fileName: String
        var path: String
        var modifiedAt: Date?

        var id: String { path }
    }

    var appPath: String
    var appVersion: String
    var buildNumber: String
    var bundleIdentifier: String
    var runningFromApplications: Bool
    var signatureStatus: String
    var gatekeeperStatus: String
    var quarantineStatus: String
    var recentCrashReportStatus: String
    var recentCrashReports: [RecentCrashReport]
    var sparkleAutomaticChecksEnabled: Bool
    var sparkleFeedURL: String?
    var updateRecommendation: String

    static func current(
        bundle: Bundle = .main,
        diagnosticDirectory: URL = defaultDiagnosticDirectory(),
        now: Date = .now,
        runCommand: @Sendable (String, [String]) -> CommandResult = runSystemCommand
    ) -> InstallationDiagnosticSnapshot {
        let bundleURL = bundle.bundleURL.standardizedFileURL
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "-"
        let build = info["CFBundleVersion"] as? String ?? "-"
        let identifier = bundle.bundleIdentifier ?? "-"
        let appName = info["CFBundleDisplayName"] as? String
            ?? info["CFBundleName"] as? String
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let automaticChecks = info["SUEnableAutomaticChecks"] as? Bool ?? false
        let feedURL = info["SUFeedURL"] as? String

        let codesign = runCommand("/usr/bin/codesign", ["-dvvv", "--entitlements", ":-", bundleURL.path])
        let spctl = runCommand("/usr/sbin/spctl", ["-a", "-vv", bundleURL.path])
        let xattr = runCommand("/usr/bin/xattr", ["-p", "com.apple.quarantine", bundleURL.path])
        let crashReports = recentCrashReports(
            appName: appName,
            diagnosticDirectory: diagnosticDirectory,
            since: now.addingTimeInterval(-24 * 60 * 60)
        )

        return InstallationDiagnosticSnapshot(
            appPath: bundleURL.path,
            appVersion: version,
            buildNumber: build,
            bundleIdentifier: identifier,
            runningFromApplications: bundleURL.path.hasPrefix("/Applications/"),
            signatureStatus: signatureSummary(from: codesign),
            gatekeeperStatus: gatekeeperSummary(from: spctl),
            quarantineStatus: quarantineSummary(from: xattr),
            recentCrashReportStatus: crashReportStatus(from: crashReports),
            recentCrashReports: crashReports,
            sparkleAutomaticChecksEnabled: automaticChecks,
            sparkleFeedURL: feedURL,
            updateRecommendation: updateRecommendation(automaticChecksEnabled: automaticChecks)
        )
    }

    static func signatureSummary(from result: CommandResult) -> String {
        guard result.status == 0 else { return "无法读取签名信息" }
        if result.output.contains("Signature=adhoc") { return "ad-hoc 签名，未使用 Developer ID" }
        if let authority = firstCapture(in: result.output, pattern: #"Authority=([^\n]+)"#),
           !authority.isEmpty {
            if authority.contains("Developer ID") {
                return authority
            }
            return "固定证书签名（\(authority)）"
        }
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
            ? "App 内 Sparkle 自动检查更新已开启；后续更新会优先通过已签名 appcast 完成，避免反复手动下载新包。"
            : "App 内 Sparkle 自动检查更新已关闭；手动从浏览器下载新版仍可能带隔离属性。"
    }

    static func recentCrashReports(
        appName: String,
        diagnosticDirectory: URL = defaultDiagnosticDirectory(),
        since: Date = .now.addingTimeInterval(-24 * 60 * 60),
        fileManager: FileManager = .default
    ) -> [RecentCrashReport] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: diagnosticDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let appNameVariants = Set([
            appName,
            appName.replacingOccurrences(of: " ", with: "_"),
            appName.replacingOccurrences(of: "_", with: " "),
        ])
        let reports = files.compactMap { url -> RecentCrashReport? in
            let fileName = url.lastPathComponent
            let extensionName = url.pathExtension.lowercased()
            guard extensionName == "crash" || extensionName == "ips" else { return nil }
            guard appNameVariants.contains(where: { fileName.hasPrefix($0) }) else { return nil }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            if let modifiedAt = values.contentModificationDate, modifiedAt < since { return nil }
            return RecentCrashReport(
                fileName: fileName,
                path: url.path,
                modifiedAt: values.contentModificationDate
            )
        }
        .sorted {
            ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
        }
        return Array(reports.prefix(5))
    }

    static func crashReportStatus(from reports: [RecentCrashReport]) -> String {
        reports.isEmpty
            ? "最近 24 小时未发现崩溃报告"
            : "最近 24 小时发现 \(reports.count) 个崩溃报告"
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

    private static func defaultDiagnosticDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/DiagnosticReports", directoryHint: .isDirectory)
    }
}

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
