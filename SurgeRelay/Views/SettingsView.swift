import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showsWebQRCode = false
    @State private var installationDiagnostics: InstallationDiagnosticSnapshot?
    @State private var selectedTab: SettingsTab = .general

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case general
        case publishing
        case credentials
        case webManagement
        case diagnostics

        var id: Self { self }

        var title: String {
            switch self {
            case .general: "通用"
            case .publishing: "发布"
            case .credentials: "凭据"
            case .webManagement: "Web 管理"
            case .diagnostics: "诊断"
            }
        }

        var controlWidth: CGFloat {
            switch self {
            case .webManagement: 94
            default: 72
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader

            selectedSettingsContent
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 440, idealHeight: 500)
        .background {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
        }
        .background(SettingsWindowChromeConfigurator())
        .task {
            refreshInstallationDiagnostics()
            if !AppRuntimeOptions.isUIQAMode {
                model.ensureGitHubTokenLoaded()
                model.ensureWebAccessTokenForEditing()
            }
        }
        .sheet(isPresented: $showsWebQRCode) {
            if let url = model.webManagementURL, let displayURL = model.webManagementDisplayURL {
                VStack(spacing: 18) {
                    Text("Web 管理").font(.title2.bold())
                    if let image = qrCodeImage(for: url.absoluteString) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 240, height: 240)
                    }
                    Text(displayURL.absoluteString)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Button("完成") { showsWebQRCode = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(28)
                .frame(minWidth: 330)
            }
        }
    }

    private var settingsHeader: some View {
        HStack {
            Spacer(minLength: 0)
            settingsTabSelector
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var settingsTabSelector: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                settingsTabButton(tab)
            }
        }
        .padding(4)
        .frame(width: SettingsTabMetrics.selectorWidth, height: SettingsTabMetrics.selectorHeight)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .accessibilityLabel("设置分类")
    }

    private func settingsTabButton(_ tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                selectedTab = tab
            }
        } label: {
            ZStack {
                Text(tab.title)
                    .font(.callout.weight(isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(width: tab.controlWidth, height: SettingsTabMetrics.itemHeight)
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.22), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
    }

    @ViewBuilder
    private var selectedSettingsContent: some View {
        switch selectedTab {
        case .general:
            SettingsGeneralView()
        case .publishing:
            SettingsPublishingView()
        case .credentials:
            SettingsCredentialsView()
        case .webManagement:
            SettingsWebManagementView(showsWebQRCode: $showsWebQRCode)
        case .diagnostics:
            diagnosticsSettings
        }
    }

    private var diagnosticsSettings: some View {
        SettingsForm {
            SettingsSection("安装与权限") {
                installationDiagnosticsContent
            }
            SettingsSection("诊断") {
                DisclosureGroup("最近更新") {
                    if model.updateHistory.isEmpty {
                        Text("暂无记录").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.updateHistory.prefix(20)) { entry in
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
                    }
                }
                HStack {
                    Button("导出诊断…", systemImage: "square.and.arrow.up") { exportDiagnostics() }
                    Button("清除历史", role: .destructive) { model.clearUpdateHistory() }
                        .disabled(model.updateHistory.isEmpty)
                }
            }
        }
    }

    private var installationDiagnosticsContent: some View {
        Group {
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
                if !diagnostics.recentCrashReports.isEmpty {
                    DisclosureGroup("最近崩溃报告") {
                        ForEach(diagnostics.recentCrashReports) { report in
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

    private func qrCodeImage(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
