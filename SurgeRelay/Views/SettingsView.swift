import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct SettingsView: View {
    private let settingsContentMaxWidth: CGFloat = 680
    private let settingsHorizontalPadding: CGFloat = 22

    @Environment(AppModel.self) private var model
    @State private var isCheckingUpdate = false
    @State private var isTesting = false
    @State private var connectionResult: ConnectionResult?
    @State private var showsWebQRCode = false
    @State private var installationDiagnostics: InstallationDiagnosticSnapshot?
    @State private var localRootDiagnostics: LocalModuleRootDiagnosticSnapshot?
    @State private var selectedTab: SettingsTab = .general

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
            refreshLocalRootDiagnostics()
            if !AppRuntimeOptions.isUIQAMode {
                model.ensureGitHubTokenLoaded()
                model.ensureWebAccessTokenForEditing()
            }
        }
        .onChange(of: model.settings.localModuleDirectory) { _, _ in
            refreshLocalRootDiagnostics()
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
            generalSettings
        case .publishing:
            publishingSettings
        case .credentials:
            credentialsSettings
        case .webManagement:
            webManagementSettings
        case .diagnostics:
            diagnosticsSettings
        }
    }

    private var generalSettings: some View {
        settingsForm {
            settingsSection("通用") {
                SettingsControlRow("配置储存目录", icon: "folder") {
                    pathSelectionControl(
                        path: model.configurationDirectoryPath,
                        chooseAction: chooseDirectory
                    )
                }
                settingsToggleRow("使用总模块功能", icon: "square.stack.3d.up", isOn: Binding(
                    get: { model.settings.combinedModuleEnabled },
                    set: { model.setCombinedModuleEnabled($0) }
                ))
                if model.settings.combinedModuleEnabled {
                    settingsTextFieldRow("总模块文件名", icon: "doc", text: combinedFileNameBinding, prompt: "Surge-Relay")
                }
            }

            settingsSection("自动化") {
                SettingsControlRow("刷新间隔", icon: "clock.arrow.circlepath") {
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
                    .labelsHidden()
                    .frame(maxWidth: 220, alignment: .leading)
                }
                settingsToggleRow("登录时启动", icon: "power", isOn: Binding(
                    get: { model.settings.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                settingsToggleRow("自动发布", icon: "arrow.up.doc", isOn: Binding(
                    get: { model.settings.automaticallyPublish },
                    set: { model.settings.automaticallyPublish = $0; model.saveSettings() }
                ))
            }

            settingsSection("Script-Hub") {
                settingsInfoRow(
                    "版本",
                    value: model.upstreamState.revision.map { String($0.prefix(7)) } ?? "—",
                    icon: "number",
                    monospaced: true
                )
                settingsInfoRow(
                    "固定来源",
                    value: model.upstreamState.sourceDescription ?? "尚未验证",
                    icon: "pin"
                )
                settingsInfoRow(
                    "上游 revision",
                    value: model.upstreamState.upstreamRevision.map { String($0.prefix(12)) } ?? "—",
                    icon: "arrow.triangle.branch",
                    monospaced: true
                )
                settingsInfoRow(
                    "脚本 hash",
                    value: model.upstreamState.scriptHashes.isEmpty ? "尚未记录" : "\(model.upstreamState.scriptHashes.count) 个脚本已记录",
                    icon: "checklist"
                )
                settingsInfoRow(
                    "上次检查",
                    value: model.upstreamState.lastCheckedAt?.formatted(date: .abbreviated, time: .shortened) ?? "尚未检查",
                    icon: "clock"
                )
                SettingsControlRow("上游模块", icon: "link") {
                    TextField("上游模块", text: stringBinding(\.scriptHubModuleURL))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }
                settingsToggleRow("自动更新", icon: "arrow.triangle.2.circlepath", isOn: Binding(
                    get: { model.settings.automaticallyUpdateScriptHub },
                    set: { model.settings.automaticallyUpdateScriptHub = $0; model.saveSettings() }
                ))
                SettingsControlRow("操作", icon: "ellipsis.circle") {
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
                }
                if let error = model.upstreamState.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var publishingSettings: some View {
        settingsForm {
            settingsSection("存储位置") {
                SettingsControlRow("模块发布到", icon: "shippingbox") {
                    Picker("模块发布到", selection: storageModeBinding) {
                        Text("本地").tag(StorageMode.local)
                        Text("GitHub").tag(StorageMode.gitHub)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }

                if model.settings.storageMode == .local {
                    SettingsControlRow("本地根目录", icon: "folder") {
                        pathSelectionControl(
                            path: model.settings.localModuleDirectory,
                            chooseAction: chooseLocalModuleDirectory
                        )
                    }
                    SettingsInfoRow("文件规则", icon: "folder.badge.gearshape") {
                        Text(model.settings.combinedModuleEnabled ? "总模块保存在根目录；独立模块可选择根目录下的文件夹。" : "独立模块可选择根目录下的文件夹。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let diagnostics = localRootDiagnostics {
                        localRootDiagnosticContent(diagnostics)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在检查本地模块根目录…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if model.settings.storageMode == .gitHub {
                    settingsTextFieldRow("所有者", icon: "person", text: githubBinding(\.owner), prompt: "GitHub 用户或组织")
                    settingsTextFieldRow("仓库", icon: "tray.full", text: githubBinding(\.repository), prompt: "Repository")
                    settingsTextFieldRow("分支", icon: "arrow.triangle.branch", text: githubBinding(\.branch), prompt: "main")
                    settingsTextFieldRow("模块根目录", icon: "folder", text: githubBinding(\.directory), prompt: "modules")
                    SettingsInfoRow("仓库类型", icon: repositoryTypeIcon) {
                        switch model.settings.github.repositoryIsPrivate {
                        case .some(true): Label("私有", systemImage: "lock.fill")
                        case .some(false): Label("公开", systemImage: "globe")
                        case nil: Text("未检测").foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if model.settings.storageMode == .gitHub, model.settings.github.repositoryIsPrivate == true {
                settingsSection("Cloudflare Worker") {
                    settingsTextFieldRow("公共地址", icon: "network", text: githubBinding(\.publicBaseURL), prompt: "https://example.workers.dev")
                }
            }
        }
    }

    private var credentialsSettings: some View {
        settingsForm {
            settingsSection("GitHub Token") {
                settingsSecureFieldRow("Token", icon: "key.fill", text: Binding(
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
                        Button("保存到钥匙串", systemImage: "key.fill") { model.saveGitHubToken() }
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

            settingsSection("Web 管理令牌") {
                settingsSecureFieldRow("令牌", icon: "network.badge.shield.half.filled", text: Binding(
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
                        Button("保存到钥匙串", systemImage: "key.fill") { model.saveWebAccessToken() }
                        Button("生成新令牌", systemImage: "arrow.triangle.2.circlepath") { model.resetWebAccessToken() }
                        Button("拷贝令牌", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.webAccessToken, forType: .string)
                        }
                        .disabled(model.webAccessToken.isEmpty)
                    }
                }
            }

            settingsSection("钥匙串状态") {
                keychainDiagnosticsContent
            }
        }
        .onAppear {
            if !AppRuntimeOptions.isUIQAMode {
                model.ensureGitHubTokenLoaded()
                model.ensureWebAccessTokenForEditing()
            }
        }
    }

    private var webManagementSettings: some View {
        settingsForm {
            settingsSection("服务") {
                SettingsInfoRow("服务状态", icon: model.webServerState.systemImage) {
                    Label(model.webServerState.title, systemImage: model.webServerState.systemImage)
                        .foregroundStyle(webServerStateColor)
                        .textSelection(.enabled)
                }
                settingsToggleRow("启用服务", icon: "network", isOn: Binding(
                    get: { model.settings.webServerEnabled },
                    set: {
                        model.settings.webServerEnabled = $0
                        model.applyWebServerSettings()
                    }
                ))
                SettingsControlRow("端口", icon: "number") {
                    TextField("端口", value: Binding(
                        get: { model.settings.webServerPort },
                        set: { model.settings.webServerPort = $0 }
                    ), format: .number.grouping(.never))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120, alignment: .leading)
                    .onChange(of: model.settings.webServerPort) { _, _ in
                        if model.settings.webServerEnabled {
                            model.applyWebServerSettings()
                        }
                    }
                }
                settingsToggleRow("局域网访问", icon: "network", isOn: Binding(
                    get: { model.settings.webServerAllowRemoteAccess },
                    set: {
                        model.settings.webServerAllowRemoteAccess = $0
                        model.applyWebServerSettings()
                    }
                ))
                .disabled(!model.settings.webServerEnabled)
                if model.settings.webServerEnabled {
                    SettingsInfoRow("访问范围", icon: model.settings.webServerAllowRemoteAccess ? "network" : "desktopcomputer") {
                        Label(
                            model.webManagementAccessModeTitle,
                            systemImage: model.settings.webServerAllowRemoteAccess ? "network" : "desktopcomputer"
                        )
                        .foregroundStyle(model.settings.webServerAllowRemoteAccess ? .orange : .secondary)
                    }
                }
                if let failure = model.webServerState.failureMessage {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            settingsSection("访问") {
                if let displayURL = model.webManagementDisplayURL, let url = model.webManagementURL {
                    settingsInfoRow(
                        model.settings.webServerAllowRemoteAccess ? "局域网地址" : "本机地址",
                        value: displayURL.absoluteString,
                        icon: "link",
                        monospaced: true,
                        copyValue: url.absoluteString
                    )
                    SettingsControlRow("操作", icon: "ellipsis.circle") {
                        HStack {
                            Button("打开", systemImage: "safari") { NSWorkspace.shared.open(url) }
                            Button("拷贝访问链接", systemImage: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            }
                            Button("二维码", systemImage: "qrcode") { showsWebQRCode = true }
                        }
                    }
                    if model.settings.webServerAllowRemoteAccess {
                        Label("局域网访问会暴露模块管理入口，请只在可信网络中启用。", systemImage: "lock.open.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("启用 Web 管理后会显示访问地址。")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var diagnosticsSettings: some View {
        settingsForm {
            settingsSection("安装与权限") {
                installationDiagnosticsContent
            }
            settingsSection("诊断") {
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

    private func settingsForm<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        GeometryReader { geometry in
            let contentWidth = max(
                360,
                min(settingsContentMaxWidth, geometry.size.width - settingsHorizontalPadding * 2)
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content()
                }
                .frame(width: contentWidth, alignment: .topLeading)
                .padding(.horizontal, settingsHorizontalPadding)
                .padding(.top, 18)
                .padding(.bottom, 24)
                .frame(width: geometry.size.width, alignment: .top)
            }
            .scrollIndicators(.visible)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 11) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.18), lineWidth: 0.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsInfoRow(
        _ title: String,
        value: String,
        icon: String,
        monospaced: Bool = false,
        copyValue: String? = nil
    ) -> some View {
        SettingsInfoRow(title, icon: icon) {
            copyableSettingsValue(
                value,
                monospaced: monospaced,
                copyValue: copyValue
            )
        }
    }

    private func pathSelectionControl(path: String, chooseAction: @escaping () -> Void) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                copyableSettingsValue(path, monospaced: true, copyValue: path)
                Button("选择…", action: chooseAction)
            }
            VStack(alignment: .leading, spacing: 8) {
                copyableSettingsValue(path, monospaced: true, copyValue: path)
                Button("选择…", action: chooseAction)
            }
        }
    }

    @ViewBuilder
    private func copyableSettingsValue(
        _ value: String,
        monospaced: Bool = false,
        copyValue: String? = nil
    ) -> some View {
        if let copyValue {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    settingsValueText(value, monospaced: monospaced, fixedHorizontal: true)
                    TextCopyButton(text: copyValue)
                        .layoutPriority(1)
                }
                VStack(alignment: .leading, spacing: 7) {
                    settingsValueText(value, monospaced: monospaced, fixedHorizontal: false)
                    TextCopyButton(text: copyValue)
                }
            }
        } else {
            settingsValueText(value, monospaced: monospaced, fixedHorizontal: false)
        }
    }

    private func settingsValueText(
        _ value: String,
        monospaced: Bool,
        fixedHorizontal: Bool
    ) -> some View {
        Text(value)
            .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: fixedHorizontal, vertical: true)
            .frame(maxWidth: fixedHorizontal ? nil : .infinity, alignment: .leading)
    }

    private func settingsTextFieldRow(
        _ title: String,
        icon: String,
        text: Binding<String>,
        prompt: String? = nil
    ) -> some View {
        SettingsControlRow(title, icon: icon) {
            if let prompt {
                TextField(title, text: text, prompt: Text(prompt))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField(title, text: text)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func settingsSecureFieldRow(
        _ title: String,
        icon: String,
        text: Binding<String>
    ) -> some View {
        SettingsControlRow(title, icon: icon) {
            SecureField(title, text: text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
        }
    }

    private func settingsToggleRow(
        _ title: String,
        icon: String,
        isOn: Binding<Bool>
    ) -> some View {
        SettingsControlRow(title, icon: icon) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var installationDiagnosticsContent: some View {
        Group {
            if let diagnostics = installationDiagnostics {
                settingsInfoRow("版本", value: "\(diagnostics.appVersion) (\(diagnostics.buildNumber))", icon: "app")
                settingsInfoRow(
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
                    settingsInfoRow(
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

    private var keychainDiagnosticsContent: some View {
        let credentials = model.credentialDiagnostics()
        return Group {
            settingsInfoRow(
                "服务",
                value: credentials.keychainService,
                icon: "key.fill",
                monospaced: true,
                copyValue: credentials.keychainService
            )
            SettingsInfoRow("访问检查", icon: "checkmark.shield") {
                VStack(alignment: .leading, spacing: 2) {
                    Label(credentials.keychainAccessStatus, systemImage: credentials.keychainAccessState.systemImage)
                        .foregroundStyle(keychainAccessProbeColor(credentials.keychainAccessState))
                    if let checkedAt = credentials.keychainAccessCheckedAt {
                        Text(checkedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Text(credentials.keychainAccessMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let statusCode = credentials.keychainAccessStatusCode {
                SettingsInfoRow("错误码", icon: "number") {
                    Text("OSStatus \(statusCode)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if !credentials.keychainAccessRecoverySuggestion.isEmpty {
                Label(credentials.keychainAccessRecoverySuggestion, systemImage: "wrench.and.screwdriver")
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
            Button("重新检查", systemImage: "arrow.clockwise") {
                model.refreshKeychainAccessProbe()
            }
            .disabled(credentials.keychainAccessState == .checking)
        }
    }

    private var githubTokenStorageImage: String {
        switch model.githubTokenStorageStatus {
        case .keychain: "checkmark.circle.fill"
        case .notChecked, .notConfigured: "questionmark.circle"
        case .legacyConfigurationFallback, .memoryOnly, .unavailable: "exclamationmark.triangle.fill"
        }
    }

    private var githubTokenStorageColor: Color {
        switch model.githubTokenStorageStatus {
        case .keychain: .green
        case .notChecked, .notConfigured: .secondary
        case .legacyConfigurationFallback, .memoryOnly, .unavailable: .orange
        }
    }

    private var repositoryTypeIcon: String {
        switch model.settings.github.repositoryIsPrivate {
        case .some(true): "lock.fill"
        case .some(false): "globe"
        case nil: "questionmark.circle"
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
        switch model.webAccessTokenStorageStatus {
        case .keychain: "key.fill"
        case .notChecked, .notConfigured: "questionmark.circle"
        case .legacyConfigurationFallback, .memoryOnly, .unavailable: "exclamationmark.triangle.fill"
        }
    }

    private var webAccessTokenStorageColor: Color {
        switch model.webAccessTokenStorageStatus {
        case .keychain: .green
        case .notChecked, .notConfigured: .secondary
        case .legacyConfigurationFallback, .memoryOnly, .unavailable: .orange
        }
    }

    private func keychainAccessProbeColor(_ state: KeychainAccessProbeState) -> Color {
        switch state {
        case .available: .green
        case .unavailable: .orange
        case .checking, .notChecked: .secondary
        }
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

    private func refreshLocalRootDiagnostics() {
        Task { @MainActor in
            let path = model.settings.localModuleDirectory
            let snapshot = await Task.detached(priority: .utility) {
                LocalModuleRootDiagnosticSnapshot.current(path: path)
            }.value
            localRootDiagnostics = snapshot
        }
    }

    private func diagnosticLabel(_ title: String, value: String, systemImage: String) -> some View {
        SettingsInfoRow(title, icon: systemImage) {
            Label(value, systemImage: systemImage)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func localRootDiagnosticContent(_ diagnostics: LocalModuleRootDiagnosticSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsInfoRow("根目录状态", icon: "folder") {
                Label(diagnostics.status, systemImage: localRootDiagnosticImage(diagnostics))
                    .foregroundStyle(localRootDiagnosticColor(diagnostics))
                    .textSelection(.enabled)
            }
            SettingsInfoRow("写入权限", icon: diagnostics.isWritable ? "pencil" : "lock.fill") {
                Label(diagnostics.isWritable ? "可写" : "不可写", systemImage: diagnostics.isWritable ? "pencil" : "lock.fill")
                    .foregroundStyle(diagnostics.isWritable ? .green : .orange)
            }
            settingsInfoRow(
                "目录内容",
                value: "\(diagnostics.folderCount) 个文件夹 · \(diagnostics.moduleFileCount) 个 .sgmodule",
                icon: "shippingbox"
            )
            if let error = diagnostics.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button("重新检查", systemImage: "arrow.clockwise") {
                    refreshLocalRootDiagnostics()
                }
                Button("在 Finder 中显示", systemImage: "folder") {
                    NSWorkspace.shared.open(URL(filePath: diagnostics.path, directoryHint: .isDirectory))
                }
                .disabled(!diagnostics.exists || !diagnostics.isDirectory)
            }
        }
    }

    private func localRootDiagnosticImage(_ diagnostics: LocalModuleRootDiagnosticSnapshot) -> String {
        if diagnostics.exists, diagnostics.isDirectory, diagnostics.isWritable, diagnostics.error == nil {
            return "checkmark.circle.fill"
        }
        return "exclamationmark.triangle.fill"
    }

    private func localRootDiagnosticColor(_ diagnostics: LocalModuleRootDiagnosticSnapshot) -> Color {
        diagnostics.exists && diagnostics.isDirectory && diagnostics.isWritable && diagnostics.error == nil
            ? .green
            : .orange
    }

    private func credentialLabel(_ title: String, account: String, status: String) -> some View {
        let storedInKeychain = status == CredentialStorageStatus.keychain.title
        let neutral = status == CredentialStorageStatus.notConfigured.title ||
            status == CredentialStorageStatus.notChecked.title
        return SettingsInfoRow(title, icon: storedInKeychain ? "checkmark.circle.fill" : (neutral ? "questionmark.circle" : "exclamationmark.triangle.fill")) {
            VStack(alignment: .leading, spacing: 2) {
                Label(
                    status,
                    systemImage: storedInKeychain
                        ? "checkmark.circle.fill"
                        : (neutral ? "questionmark.circle" : "exclamationmark.triangle.fill")
                )
                .foregroundStyle(storedInKeychain ? .green : (neutral ? .secondary : .orange))
                Text(account)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
    }

    private func githubCommitURL(for commitSHA: String) -> URL? {
        GitHubPublishSnapshot.commitURL(for: commitSHA, settings: model.settings.github)
            .flatMap(URL.init(string:))
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

private struct SettingsWindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWhenReady(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWhenReady(nsView)
    }

    private func configureWhenReady(_ view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
        }
    }
}

private enum SettingsTabMetrics {
    static let selectorWidth: CGFloat = 406
    static let selectorHeight: CGFloat = 40
    static let itemHeight: CGFloat = 30
}

private struct SettingsInfoRow<Content: View>: View {
    let title: String
    let icon: String
    private let content: () -> Content

    init(_ title: String, icon: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: 108, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.14))
                .frame(height: 0.5)
                .padding(.leading, 30)
        }
    }
}

private struct SettingsControlRow<Content: View>: View {
    let title: String
    let icon: String
    private let content: () -> Content

    init(_ title: String, icon: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content
    }

    var body: some View {
        SettingsInfoRow(title, icon: icon) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
