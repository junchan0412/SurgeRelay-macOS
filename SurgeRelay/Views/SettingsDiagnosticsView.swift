import AppKit
import SwiftUI

struct SettingsDiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var installationDiagnostics: InstallationDiagnosticSnapshot?

    var body: some View {
        SettingsForm {
            SettingsSection("安装与权限") {
                installationDiagnosticsContent
            }
            SettingsSection("诊断") {
                updateHistorySection
                HStack {
                    Button("导出诊断…", systemImage: "square.and.arrow.up") { exportDiagnostics() }
                    Button("清除历史", role: .destructive) { model.clearUpdateHistory() }
                        .disabled(model.updateHistory.isEmpty)
                }
            }
        }
        .task {
            refreshInstallationDiagnostics()
        }
    }

    @ViewBuilder
    private var installationDiagnosticsContent: some View {
        if let diagnostics = installationDiagnostics {
            SettingsCopyableInfoRow(
                "版本",
                value: "\(diagnostics.appVersion) (\(diagnostics.buildNumber))",
                icon: "app"
            )
            SettingsCopyableInfoRow(
                "App 位置",
                value: diagnostics.appPath,
                icon: "folder",
                monospaced: true,
                copyValue: diagnostics.appPath
            )
            diagnosticLabel("签名", value: diagnostics.signatureStatus, systemImage: "signature")
            diagnosticLabel("Gatekeeper", value: diagnostics.gatekeeperStatus, systemImage: "lock.shield")
            diagnosticLabel("隔离属性", value: diagnostics.quarantineStatus, systemImage: "shield.lefthalf.filled")
            diagnosticLabel("崩溃报告", value: diagnostics.recentCrashReportStatus, systemImage: "waveform.path.ecg")
            recentCrashReports(diagnostics.recentCrashReports)
            SettingsInfoRow("自动检查更新", icon: "magnifyingglass.circle") {
                Label(
                    diagnostics.sparkleAutomaticChecksEnabled ? "开启" : "关闭",
                    systemImage: diagnostics.sparkleAutomaticChecksEnabled ? "checkmark.circle.fill" : "pause.circle"
                )
                .foregroundStyle(diagnostics.sparkleAutomaticChecksEnabled ? .green : .secondary)
            }
            if let feedURL = diagnostics.sparkleFeedURL {
                SettingsCopyableInfoRow(
                    "更新源",
                    value: feedURL,
                    icon: "antenna.radiowaves.left.and.right",
                    monospaced: true,
                    copyValue: feedURL
                )
            }
            Label(diagnostics.updateRecommendation, systemImage: "shippingbox")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("重新检查", systemImage: "arrow.clockwise") {
                refreshInstallationDiagnostics()
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在读取安装状态…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var updateHistorySection: some View {
        DisclosureGroup("最近更新") {
            if model.updateHistory.isEmpty {
                Text("暂无记录").foregroundStyle(.secondary)
            } else {
                ForEach(model.updateHistory.prefix(20)) { entry in
                    updateHistoryEntry(entry)
                }
            }
        }
    }

    @ViewBuilder
    private func recentCrashReports(_ reports: [InstallationDiagnosticSnapshot.RecentCrashReport]) -> some View {
        if !reports.isEmpty {
            DisclosureGroup("最近崩溃报告") {
                ForEach(reports) { report in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(report.fileName)
                            .font(.caption.weight(.medium))
                            .textSelection(.enabled)
                        if let modifiedAt = report.modifiedAt {
                            Text(modifiedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(report.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func updateHistoryEntry(_ entry: UpdateHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.moduleName)
                    Text(entry.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(entry.outcome.title)
                        .font(.caption)
                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if entry.outcome == .published, entry.publishedChangeCount > 0 || entry.commitSHA != nil {
                HStack(spacing: 8) {
                    if let commitSHA = entry.commitSHA, !commitSHA.isEmpty {
                        if let commitURL = githubCommitURL(for: commitSHA) {
                            Link("Commit \(commitSHA.prefix(8))", destination: commitURL)
                                .font(.caption)
                        } else {
                            Text("Commit \(commitSHA.prefix(8))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("\(entry.publishedFiles.count) 个上传/更新 · \(entry.deletedFiles.count) 个删除")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func refreshInstallationDiagnostics() {
        Task { @MainActor in
            let snapshot = await Task.detached(priority: .utility) {
                InstallationDiagnosticSnapshot.current()
            }.value
            installationDiagnostics = snapshot
        }
    }

    private func diagnosticLabel(_ title: String, value: String, systemImage: String) -> some View {
        SettingsInfoRow(title, icon: systemImage) {
            Label(value, systemImage: systemImage)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func githubCommitURL(for commitSHA: String) -> URL? {
        GitHubPublishSnapshot.commitURL(for: commitSHA, settings: model.settings.github)
            .flatMap(URL.init(string:))
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Surge-Relay-Diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.diagnosticsData().write(to: url, options: .atomic)
        } catch {
            model.presentedError = "无法导出诊断：\(error.localizedDescription)"
        }
    }
}
