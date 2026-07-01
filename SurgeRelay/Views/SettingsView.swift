import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isCheckingUpdate = false
    @State private var isTesting = false
    @State private var connectionResult: ConnectionResult?
    @State private var showsWebQRCode = false
    @State private var installationDiagnostics: InstallationDiagnosticSnapshot?

    private enum ConnectionResult {
        case success(String)
        case failure(String)
        var message: String {
            switch self {
            case let .success(text), let .failure(text): return text
            }
        }
        var isError: Bool {
            if case .failure = self { return true }
            return false
        }
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section("通用") {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("配置储存目录")
                        Text(model.configurationDirectoryPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("选择…") { chooseDirectory() }
                }
                TextField("总模块文件名", text: combinedFileNameBinding)
            }

            Section("自动化") {
                Picker("刷新间隔", selection: Binding(
                    get: { model.settings.refreshIntervalMinutes },
                    set: {
                        model.settings.refreshIntervalMinutes = $0
                        model.saveSettings()
                        model.restartScheduler()
                    }
                )) {
                    Text("手动").tag(0)
                    Text("每 15 分钟").tag(15)
                    Text("每小时").tag(60)
                    Text("每 6 小时").tag(360)
                    Text("每 12 小时").tag(720)
                }
                Toggle("登录时启动 Surge Relay", isOn: Binding(
                    get: { model.settings.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Toggle("自动发布", isOn: Binding(
                    get: { model.settings.automaticallyPublish },
                    set: { model.settings.automaticallyPublish = $0; model.saveSettings() }
                ))
            }

            Section("安装与权限") {
                if let diagnostics = installationDiagnostics {
                    LabeledContent("版本") {
                        Text("\(diagnostics.appVersion) (\(diagnostics.buildNumber))")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("App 位置") {
                        Text(diagnostics.appPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    diagnosticLabel("签名", value: diagnostics.signatureStatus, systemImage: "signature")
                    diagnosticLabel("Gatekeeper", value: diagnostics.gatekeeperStatus, systemImage: "lock.shield")
                    diagnosticLabel("隔离属性", value: diagnostics.quarantineStatus, systemImage: "shield.lefthalf.filled")
                    LabeledContent("自动检查更新") {
                        Label(
                            diagnostics.sparkleAutomaticChecksEnabled ? "开启" : "关闭",
                            systemImage: diagnostics.sparkleAutomaticChecksEnabled ? "checkmark.circle.fill" : "pause.circle"
                        )
                        .foregroundStyle(diagnostics.sparkleAutomaticChecksEnabled ? .green : .secondary)
                    }
                    if let feedURL = diagnostics.sparkleFeedURL {
                        LabeledContent("更新源") {
                            Text(feedURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
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

            Section("钥匙串") {
                let credentials = model.credentialDiagnostics()
                LabeledContent("服务") {
                    Text(credentials.keychainService)
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
                Label(credentials.note, systemImage: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Web 管理") {
                LabeledContent("服务状态") {
                    Label(model.webServerState.title, systemImage: model.webServerState.systemImage)
                        .foregroundStyle(webServerStateColor)
                        .textSelection(.enabled)
                }
                Toggle("启用 Web 管理", isOn: Binding(
                    get: { model.settings.webServerEnabled },
                    set: {
                        model.settings.webServerEnabled = $0
                        model.applyWebServerSettings()
                    }
                ))
                TextField("端口", value: Binding(
                    get: { model.settings.webServerPort },
                    set: { model.settings.webServerPort = $0 }
                ), format: .number.grouping(.never))
                .onChange(of: model.settings.webServerPort) { _, _ in
                    if model.settings.webServerEnabled {
                        model.applyWebServerSettings()
                    }
                }
                Toggle("允许局域网访问", isOn: Binding(
                    get: { model.settings.webServerAllowRemoteAccess },
                    set: {
                        model.settings.webServerAllowRemoteAccess = $0
                        model.applyWebServerSettings()
                    }
                ))
                .disabled(!model.settings.webServerEnabled)
                if model.settings.webServerEnabled {
                    LabeledContent("访问范围") {
                        Label(
                            model.webManagementAccessModeTitle,
                            systemImage: model.settings.webServerAllowRemoteAccess ? "network" : "desktopcomputer"
                        )
                        .foregroundStyle(model.settings.webServerAllowRemoteAccess ? .orange : .secondary)
                    }
                    LabeledContent("令牌存储") {
                        Label(model.webAccessTokenStorageStatus.title, systemImage: webAccessTokenStorageImage)
                            .foregroundStyle(webAccessTokenStorageColor)
                            .textSelection(.enabled)
                    }
                }
                if let failure = model.webServerState.failureMessage {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if let displayURL = model.webManagementDisplayURL, let url = model.webManagementURL {
                    LabeledContent(model.settings.webServerAllowRemoteAccess ? "局域网地址" : "本机地址") {
                        Text(displayURL.absoluteString)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button("打开", systemImage: "safari") { NSWorkspace.shared.open(url) }
                        Button("拷贝访问链接", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                        Button("二维码", systemImage: "qrcode") { showsWebQRCode = true }
                        Button("重置令牌", systemImage: "arrow.triangle.2.circlepath") {
                            model.resetWebAccessToken()
                        }
                    }
                    if model.settings.webServerAllowRemoteAccess {
                        Label("局域网访问会暴露模块管理入口，请只在可信网络中启用。", systemImage: "lock.open.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Script-Hub") {
                LabeledContent("版本") {
                    Text(model.upstreamState.revision.map { String($0.prefix(7)) } ?? "—")
                        .monospaced()
                }
                LabeledContent("上次检查") {
                    Text(model.upstreamState.lastCheckedAt?.formatted(date: .abbreviated, time: .shortened) ?? "尚未检查")
                        .foregroundStyle(.secondary)
                }
                TextField("上游模块", text: stringBinding(\.scriptHubModuleURL))
                Toggle("自动更新", isOn: Binding(
                    get: { model.settings.automaticallyUpdateScriptHub },
                    set: { model.settings.automaticallyUpdateScriptHub = $0; model.saveSettings() }
                ))
                HStack(spacing: 8) {
                    Button("检查更新", systemImage: "arrow.clockwise") {
                        Task {
                            isCheckingUpdate = true
                            await model.refreshScriptHub(showProgress: false)
                            isCheckingUpdate = false
                        }
                    }
                    .disabled(isCheckingUpdate)
                    if isCheckingUpdate {
                        ProgressView().controlSize(.small)
                        Text("正在检查…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = model.upstreamState.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }

            Section("存储位置") {
                Picker("总模块保存到", selection: storageModeBinding) {
                    Text("本地").tag(StorageMode.local)
                    Text("GitHub").tag(StorageMode.gitHub)
                }
                .pickerStyle(.segmented)

                if model.settings.storageMode == .local {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("本地模块根目录")
                            Text(model.settings.localModuleDirectory)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                            Text("总模块保存在根目录；独立模块可选择根目录下的文件夹")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button("选择…") { chooseLocalModuleDirectory() }
                    }
                }
            }

            if model.settings.storageMode == .gitHub {
            Section("GitHub") {
                TextField("所有者", text: githubBinding(\.owner))
                TextField("仓库", text: githubBinding(\.repository))
                TextField("分支", text: githubBinding(\.branch))
                TextField("模块根目录", text: githubBinding(\.directory))
                LabeledContent("仓库类型") {
                    switch model.settings.github.repositoryIsPrivate {
                    case .some(true): Label("私有", systemImage: "lock.fill")
                    case .some(false): Label("公开", systemImage: "globe")
                    case nil: Text("未检测").foregroundStyle(.secondary)
                    }
                }
            }

            Section("访问凭据") {
                SecureField("GitHub Token", text: $model.githubToken)
                HStack(spacing: 8) {
                    Button("保存") { model.saveGitHubToken() }
                        .help("GitHub Token 会保存在系统钥匙串")
                    Button("测试连接") {
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
                    .disabled(model.githubToken.isEmpty || !model.settings.github.isConfigured || isTesting)
                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                }
                if let result = connectionResult {
                    Label(result.message, systemImage: result.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(result.isError ? .red : .green)
                        .textSelection(.enabled)
                }
            }

            if model.settings.github.repositoryIsPrivate == true {
                Section("Cloudflare Worker") {
                    TextField("公共地址", text: githubBinding(\.publicBaseURL))
                }
            }
            }

            Section("诊断") {
                DisclosureGroup("最近更新") {
                    if model.updateHistory.isEmpty {
                        Text("暂无记录").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.updateHistory.prefix(20)) { entry in
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
        .formStyle(.grouped)
        .navigationTitle("设置")
        .task { refreshInstallationDiagnostics() }
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

    private var storageModeBinding: Binding<StorageMode> {
        Binding(
            get: { model.settings.storageMode },
            set: { model.setStorageMode($0) }
        )
    }

    private var webServerStateColor: Color {
        switch model.webServerState {
        case .running: .green
        case .failed: .red
        case .starting, .stopped: .secondary
        }
    }

    private var webAccessTokenStorageImage: String {
        model.webAccessTokenStorageStatus == .keychain
            ? "key.fill"
            : "exclamationmark.triangle.fill"
    }

    private var webAccessTokenStorageColor: Color {
        model.webAccessTokenStorageStatus == .keychain ? .green : .orange
    }

    private func chooseLocalModuleDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(filePath: model.settings.localModuleDirectory, directoryHint: .isDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setLocalModuleDirectory(url.path)
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
        LabeledContent(title) {
            Label(value, systemImage: systemImage)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func credentialLabel(_ title: String, account: String, status: String) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                Label(status, systemImage: status.contains("钥匙串") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(status.contains("钥匙串") ? .green : .secondary)
                Text(account)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
    }

    private func githubBinding(_ keyPath: WritableKeyPath<GitHubSettings, String>) -> Binding<String> {
        Binding(
            get: { model.settings.github[keyPath: keyPath] },
            set: {
                model.settings.github[keyPath: keyPath] = $0
                model.saveSettings()
            }
        )
    }

    /// Edits the combined module file name without the `.sgmodule` extension so it
    /// can't be deleted by accident. The on-disk file always keeps the extension,
    /// since every consumer normalizes through `FilenameSanitizer.sgmoduleName`.
    private var combinedFileNameBinding: Binding<String> {
        Binding(
            get: {
                let value = model.settings.combinedModuleFileName
                return value.lowercased().hasSuffix(".sgmodule")
                    ? String(value.dropLast(".sgmodule".count))
                    : value
            },
            set: {
                model.settings.combinedModuleFileName = $0
                model.saveSettings()
            }
        )
    }

    private func stringBinding(_ keyPath: WritableKeyPath<AppSettings, String>) -> Binding<String> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: {
                model.settings[keyPath: keyPath] = $0
                model.saveSettings()
            }
        )
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(filePath: model.configurationDirectoryPath, directoryHint: .isDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.useConfigurationDirectory(url.path)
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
