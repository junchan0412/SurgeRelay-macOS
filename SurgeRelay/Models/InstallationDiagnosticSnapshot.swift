import Foundation

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
