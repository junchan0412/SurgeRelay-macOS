import SwiftUI

struct ModuleDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var argumentInfo = ModuleArgumentInfo()
    @State private var syncComparison: ModuleSyncComparison?
    @State private var showsVersionHistory = false
    @State private var showsLint = false
    @State private var showsTemplateName = false
    @State private var templateName = ""
    let module: RelayModule
    let onEdit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                moduleSummaryHeader
                diagnosticsSection
                sourceAndOutputSection
                argumentsSection
                publishingSection
                synchronizationSection
                detailSection("发布前检查") {
                    Button("检查规则结构与脚本资源…") { showsLint = true }
                        .disabled(model.isWorking)
                }
                detailSection("复用模块设置") {
                    Button("保存为模块模板…") { templateName = module.name; showsTemplateName = true }
                        .disabled(model.isWorking)
                }
                detailSection("版本历史") {
                    Button("查看历史、比较与回退…") { showsVersionHistory = true }
                        .disabled(model.isWorking)
                }
                advancedSection
            }
            .frame(maxWidth: 940, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Design.Palette.canvas)
        .accessibilityIdentifier("module-detail.root")
        .alert("保存模块模板", isPresented: $showsTemplateName) {
            TextField("模板名称", text: $templateName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                Task {
                    do { try await model.saveModuleTemplate(moduleID: module.id, name: templateName) }
                    catch { model.presentedError = error.localizedDescription }
                }
            }
        } message: { Text("保存格式、分类、输出和常用转换选项，不复制来源地址或凭据。") }
        .sheet(isPresented: $showsLint) {
            ModuleLintView(moduleID: module.id).environment(model)
        }
        .sheet(isPresented: $showsVersionHistory) {
            ModuleVersionHistoryView(moduleID: module.id).environment(model)
        }
        .sheet(item: $syncComparison) { comparison in
            ModuleSyncComparisonView(comparison: comparison).environment(model)
        }
        .task(id: "\(module.id.uuidString)-\(module.contentHash ?? "")") {
            argumentInfo = await model.moduleArgumentInfo(for: module)
        }
    }

    private var moduleSummaryHeader: some View {
        ModuleDetailSummaryHeader(
            module: module,
            combinedModuleEnabled: model.settings.combinedModuleEnabled,
            onEdit: onEdit
        )
    }

    private var sourceAndOutputSection: some View {
        detailSection("管理关系") {
            detailRow("更新地址", value: sourceAddressDisplay, icon: "link", monospaced: true, copyValue: sourceAddressCopyValue)
            detailRow("发布位置", value: standaloneStorageDescription, icon: module.standaloneStorageSystemImage)
            detailRow("输出路径", value: module.publishedRelativePath, icon: "doc.badge.gearshape", monospaced: true, copyValue: module.publishedRelativePath)
            DisclosureGroup("来源与输出详情") {
                detailRow(
                    "独立模块存放",
                    value: standaloneStorageDescription,
                    icon: module.standaloneStorageSystemImage
                )
                detailRow("初始来源", value: module.initialSource.title, icon: module.initialSource.systemImage)
                if let initialSourceURL = module.initialSourceURL,
                   !ModuleSourceIdentity.matches(initialSourceURL, module.updateSourceURL) {
                    detailRow("订阅原始地址", value: initialSourceURL, icon: "link", monospaced: true, copyValue: initialSourceURL)
                }
                if let localStoragePath {
                    detailRow("本地相对路径", value: localStoragePath, icon: "folder", monospaced: true, copyValue: localStoragePath)
                }
                if let registeredSourceAddress {
                    detailRow("登记地址", value: registeredSourceAddress.display, icon: "link", monospaced: true, copyValue: registeredSourceAddress.copyValue)
                }
                detailRow("来源格式", value: module.sourceFormatDisplayTitle, icon: "doc.text")
                if let subscription = module.scriptHubSubscription {
                    detailRow("来源记录", value: subscription.displaySummary, icon: "point.3.connected.trianglepath.dotted")
                    detailRow("模块链接", value: subscription.subscriptionURL, icon: "link.badge.plus", monospaced: true, copyValue: subscription.subscriptionURL)
                    if let outputName = subscription.outputName {
                        detailRow("原输出名", value: outputName, icon: "doc.text", monospaced: true)
                    }
                }
                detailRow("模块标签", value: module.category.isEmpty ? "未设置" : module.category, icon: "tag")
                detailRow("存放文件夹", value: ModuleOutputFolder.displayTitle(for: module.outputFolder), icon: "folder")
                detailRow(
                    "输出文件",
                    value: module.publishesStandalone ? module.publishedRelativePath : "未开启独立发布",
                    icon: "doc.badge.gearshape",
                    monospaced: module.publishesStandalone,
                    copyValue: module.publishesStandalone ? module.publishedRelativePath : nil
                )
                detailRow("图标来源", value: module.iconSourceDescription, icon: "photo")
                if let iconURLDisplay {
                    detailRow("图标地址", value: iconURLDisplay, icon: "link", monospaced: true, copyValue: iconURLDisplay)
                }
            }
            .font(.system(size: 13))
            .padding(.vertical, 6)

        }
    }

    private var synchronizationSection: some View {
        detailSection("同步状态") {
            detailRow("更新状态", value: module.state.title, icon: module.state.systemImage)
            detailRow("上次更新", value: module.lastUpdatedAt?.formatted(date: .long, time: .standard) ?? "从未更新", icon: "clock")
            detailRow("来源检查", value: module.sourceCheckedAt?.formatted(date: .long, time: .standard) ?? "尚未检查", icon: "dot.radiowaves.left.and.right")
            detailRow("刷新策略", value: module.refreshIntervalMinutes.map { ModuleRefreshPlanner.intervalTitle($0) }
                ?? "继承全局（\(ModuleRefreshPlanner.intervalTitle(model.settings.refreshIntervalMinutes))）", icon: "clock.arrow.circlepath")
            if module.consecutiveFailureCount > 0 {
                detailRow("连续失败", value: "\(module.consecutiveFailureCount) 次；手动更新可跳过普通退避", icon: "exclamationmark.triangle")
            }
            if let date = ModuleRefreshPlanner.nextDueDate(for: module, among: model.modules, globalIntervalMinutes: model.settings.refreshIntervalMinutes) {
                detailRow("下次自动检查", value: date.formatted(date: .long, time: .standard), icon: "calendar.badge.clock")
            }
            if let date = ModuleRefreshPlanner.serverDeadline(for: module, among: model.modules), date > .now {
                detailRow("服务器限流", value: "不早于 \(date.formatted(date: .long, time: .standard))；手动更新也会等待", icon: "hourglass")
            }
            DisclosureGroup("技术信息与校验值") {
            detailRow("创建时间", value: module.createdAt.formatted(date: .long, time: .standard), icon: "calendar")
                detailRow(
                    "内容 hash",
                    value: module.contentHash.map { String($0.prefix(12)) } ?? "尚未生成",
                    icon: "number",
                    monospaced: true,
                    copyValue: module.contentHash
                )
                if let sourceContentHash = module.sourceContentHash {
                    detailRow("来源 hash", value: String(sourceContentHash.prefix(12)), icon: "number", monospaced: true, copyValue: sourceContentHash)
                }
                if let sourceETag = module.sourceETag {
                    detailRow("来源 ETag", value: sourceETag, icon: "tag", monospaced: true, copyValue: sourceETag)
                }
                if let sourceLastModified = module.sourceLastModified {
                    detailRow("来源修改时间", value: sourceLastModified, icon: "calendar.badge.clock", monospaced: true)
                }
                detailRow(
                    "转换引擎",
                    value: module.conversionEngineRevision.map { String($0.prefix(12)) } ?? "原生 Surge 模块",
                    icon: "cpu",
                    monospaced: module.conversionEngineRevision != nil,
                    copyValue: module.conversionEngineRevision
                )
                if model.settings.combinedModuleEnabled {
                    detailRow("总模块", value: module.isEnabled ? "包含" : "不包含", icon: "square.stack.3d.up")
                    detailRow(
                        "汇总输出",
                        value: combinedOutputLocation,
                        icon: "square.stack.3d.up",
                        monospaced: true,
                        copyValue: combinedOutputCopyValue
                    )
                }
            }
            .font(.system(size: 13))
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        if let summary = module.scriptHubOptions.configuredSummary {
            detailSection("高级设置") {
                Label {
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
    }

    @ViewBuilder
    private var argumentsSection: some View {
        if !argumentInfo.definitions.isEmpty {
            detailSection("模块参数") {
                ForEach(argumentInfo.definitions) { definition in
                    argumentControl(definition)
                }
                HStack {
                    Text("修改会立即应用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复默认值") {
                        model.resetModuleArguments(moduleID: module.id)
                    }
                    .disabled(module.argumentOverrides.isEmpty)
                }
                if let help = argumentInfo.helpText {
                    DisclosureGroup("参数说明") {
                        Text(help)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var publishingSection: some View {
        if model.settings.publishToGitHub, module.hasGitHubStorageTarget {
            detailSection(model.settings.github.repositoryIsPrivate == true ? "Cloudflare" : "GitHub") {
                if !module.publishesStandalone {
                    Label("该模块未开启独立发布。", systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                } else if let rawURL = model.rawURL(for: module) {
                    detailRow("订阅地址", value: rawURL.absoluteString, icon: "link", monospaced: true, copyValue: rawURL.absoluteString)
                } else {
                    Label("完成发布配置后，这里会出现该模块自己的稳定地址。", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        if model.settings.publishToLocal,
           module.hasLocalStorageTarget,
           module.publishesStandalone {
            detailSection("本地文件") {
                detailRow("文件位置", value: localPublishedPath, icon: "doc", monospaced: true, copyValue: localPublishedPath)
            }
        }
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        if let error = module.lastError {
            detailSection("最近一次更新失败") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 8) {
                        Label("更新失败", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Design.Palette.error)
                        Spacer(minLength: 0)
                        TextCopyButton(text: error, title: "复制错误")
                    }
                    Text(error).textSelection(.enabled)
                    Text(failureCacheNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        if module.hasOverrideConflict {
            detailSection("本地编辑冲突") {
                Label("上游模块已经变化，本地编辑仍在使用。请前往“预览”比较后决定保留或恢复。", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Design.Palette.warning)
            }
        }

        if let conflict = module.syncConflict {
            detailSection("本地与 GitHub 内容冲突") {
                VStack(alignment: .leading, spacing: 10) {
                    Label(conflict.comparisonState.title + "。请选择要保留的版本。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Design.Palette.warning)
                    Text("本地最后更新：\(conflict.localUpdatedAtText)")
                    Text("GitHub 最后更新：\(conflict.githubUpdatedAtText)")
                    Button("比较差异并选择覆盖方向…") { loadSyncComparison() }
                        .disabled(model.isWorking)
                    .buttonStyle(.bordered)
                }
                .font(.caption)
            }
        } else if module.hasLocalStorageTarget && module.hasGitHubStorageTarget {
            detailSection("本地与 GitHub 同步") {
                Button("比较两端内容…") { loadSyncComparison() }
                    .disabled(model.isWorking)
            }
        }
    }

    private func loadSyncComparison() {
        Task {
            do { syncComparison = try await model.moduleSyncComparison(moduleID: module.id) }
            catch { model.presentedError = error.localizedDescription }
        }
    }

    private var combinedOutputLocation: String {
        var values: [String] = []
        if let localURL = model.combinedLocalFileURL {
            values.append(localURL.path)
        }
        if let rawURL = model.combinedRawURL {
            values.append(rawURL.absoluteString)
        }
        return values.isEmpty ? "等待发布配置" : values.joined(separator: "\n")
    }

    private var combinedOutputCopyValue: String? {
        combinedOutputLocation == "等待发布配置" ? nil : combinedOutputLocation
    }

    private var localPublishedPath: String {
        URL(filePath: model.settings.localModuleDirectory, directoryHint: .isDirectory)
            .appending(path: module.publishedRelativePath)
            .path
    }

    private var localStoragePath: String? {
        guard module.hasLocalStorageTarget else { return nil }
        return module.localStorageRelativePath ?? module.publishedRelativePath
    }

    private var standaloneStorageDescription: String {
        guard !module.publishesStandalone,
              model.settings.combinedModuleEnabled,
              module.isEnabled else {
            return module.standaloneStorageDetail
        }
        return "未开启独立发布；转换结果保存在本地缓存，可作为总模块来源"
    }

    private var iconURLDisplay: String? {
        module.customIconURL ?? module.iconURL
    }

    private var sourceAddressDisplay: String {
        let sourceURL = module.updateSourceURL
        if let url = URL(string: sourceURL), url.isFileURL {
            return url.path
        }
        return sourceURL.removingPercentEncoding ?? sourceURL
    }

    private var registeredSourceAddress: (display: String, copyValue: String)? {
        guard let initialSourceURL = module.initialSourceURL,
              !ModuleSourceIdentity.matches(initialSourceURL, module.sourceURL) else {
            return nil
        }
        if let url = URL(string: module.sourceURL), url.isFileURL {
            return (url.path, url.path)
        }
        return (
            module.sourceURL.removingPercentEncoding ?? module.sourceURL,
            module.sourceURL
        )
    }

    private var sourceAddressCopyValue: String {
        let sourceURL = module.updateSourceURL
        if let url = URL(string: sourceURL), url.isFileURL {
            return url.path
        }
        return sourceURL
    }

    private var failureCacheNote: String {
        model.settings.combinedModuleEnabled
            ? "如果该来源有缓存，总模块会继续沿用它上一次成功版本。"
            : "如果该来源有缓存，模块输出会继续沿用它上一次成功版本。"
    }

    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        DetailInfoSection(title, content: content)
    }

    @ViewBuilder
    private func argumentControl(_ definition: ModuleArgumentDefinition) -> some View {
        let value = argumentValue(for: definition)
        if ["true", "false"].contains(definition.defaultValue.lowercased()) {
            DetailControlRow(label: definition.key, icon: "switch.2") {
                Toggle(definition.key, isOn: Binding(
                    get: { argumentValue(for: definition).lowercased() == "true" },
                    set: { enabled in
                        model.setModuleArgument(
                            moduleID: module.id,
                            key: definition.key,
                            value: enabled ? "true" : "false",
                            defaultValue: definition.defaultValue
                        )
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        } else {
            DetailControlRow(label: definition.key, icon: "text.cursor") {
                TextField(
                    definition.key,
                    text: Binding(
                        get: { argumentValue(for: definition) },
                        set: { newValue in
                            model.setModuleArgument(
                                moduleID: module.id,
                                key: definition.key,
                                value: newValue,
                                defaultValue: definition.defaultValue
                            )
                        }
                    ),
                    prompt: Text(definition.defaultValue)
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 180)
            }
            .help("默认值：\(definition.defaultValue)；当前值：\(value)")
        }
    }

    private func argumentValue(for definition: ModuleArgumentDefinition) -> String {
        model.modules.first(where: { $0.id == module.id })?.argumentOverrides[definition.key]
            ?? definition.defaultValue
    }

    private func detailRow(
        _ label: String,
        value: String,
        icon: String,
        monospaced: Bool = false,
        copyValue: String? = nil
    ) -> some View {
        DetailInfoRow(label: label, value: value, icon: icon, monospaced: monospaced, copyValue: copyValue)
    }
}

private struct ModuleSyncComparisonView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var comparison: ModuleSyncComparison
    @State private var pendingResolution: ModuleSyncResolution?
    @State private var confirmsOverwrite = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(comparison.metadata.comparisonState.title).font(.headline)
                    Text("本地 −\(comparison.diff.removedCount) 行 · GitHub +\(comparison.diff.addedCount) 行")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新比较") {
                    Task {
                        do { comparison = try await model.moduleSyncComparison(moduleID: comparison.moduleID) }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
                .disabled(model.isWorking)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if comparison.diff.usesCoarseComparison {
                Text("变化范围较大，按整块删除/新增显示；数量不代表最小编辑次数。")
                    .font(.caption).foregroundStyle(Design.Palette.warning)
            }
            if comparison.diff.hasFinalNewlineDifference {
                Text("两端文件的末尾换行不同。")
                    .font(.caption).foregroundStyle(Design.Palette.warning)
            }
            if comparison.diff.isTruncated {
                Text("差异较多，已省略超出 2,000 行的显示内容。")
                    .font(.caption).foregroundStyle(Design.Palette.warning)
            }
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(comparison.diff.rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 10) {
                            Text(row.localLine.map(String.init) ?? "–").frame(width: 52, alignment: .trailing)
                            Text(row.githubLine.map(String.init) ?? "–").frame(width: 52, alignment: .trailing)
                            Text(row.kind == .added ? "+" : row.kind == .removed ? "−" : " ").frame(width: 12)
                            Text(String(row.text.prefix(4_000))).textSelection(.enabled)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .frame(minWidth: 840, alignment: .leading)
                        .background(row.kind == .added ? Color.green.opacity(0.10) : row.kind == .removed ? Color.red.opacity(0.10) : Color.clear)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .background(Design.Palette.canvas)
            Text("左列为本地行号，右列为 GitHub 行号。长行仅显示前 4,000 个字符；覆盖会使用完整文件。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("不会自动覆盖单边更新，请选择要保留的版本。")
                    Text("所选内容会保留为本地编辑；后续发布仍会应用模块名称、参数和格式规范化。")
                }
                .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("本地覆盖 GitHub") { pendingResolution = .localWins; confirmsOverwrite = true }
                Button("GitHub 覆盖本地") { pendingResolution = .githubWins; confirmsOverwrite = true }
            }
            .disabled(model.isWorking || comparison.metadata.comparisonState == .same)
        }
        .padding(20)
        .frame(minWidth: 920, minHeight: 560)
        .confirmationDialog("确认按所选方向覆盖？", isPresented: $confirmsOverwrite) {
            Button(pendingResolution == .localWins ? "本地覆盖 GitHub" : "GitHub 覆盖本地", role: .destructive) {
                guard let resolution = pendingResolution else { return }
                Task {
                    if await model.resolveModuleSyncConflict(moduleID: comparison.moduleID, resolution: resolution, comparison: comparison) {
                        dismiss()
                    } else {
                        errorMessage = model.presentedError ?? "未完成同步，请重新比较后再试。"
                        model.presentedError = nil
                    }
                }
            }
        } message: {
            Text("执行前将重新核验两端版本；比较后发生变化时会停止，并要求重新比较。")
        }
        .alert("无法完成同步", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }
}
