import SwiftUI

struct ModuleDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var argumentInfo = ModuleArgumentInfo()
    let module: RelayModule
    let onEdit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                moduleSummaryHeader
                diagnosticsSection
                sourceAndOutputSection
                synchronizationSection
                advancedSection
                argumentsSection
                publishingSection
            }
            .frame(maxWidth: 760, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .top)
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
            detailRow(
                "独立模块存放",
                value: standaloneStorageDescription,
                icon: module.standaloneStorageSystemImage
            )
            detailRow("转换前来源", value: module.sourceOrigin.title, icon: module.sourceOrigin.systemImage)
            if let localStoragePath {
                detailRow("本地相对路径", value: localStoragePath, icon: "folder", monospaced: true, copyValue: localStoragePath)
            }
            detailRow("原始地址", value: sourceAddressDisplay, icon: "link", monospaced: true, copyValue: sourceAddressCopyValue)
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
            detailRow("图标来源", value: iconSourceDescription, icon: "photo")
            if let iconURLDisplay {
                detailRow("图标地址", value: iconURLDisplay, icon: "link", monospaced: true, copyValue: iconURLDisplay)
            }
        }
    }

    private var synchronizationSection: some View {
        detailSection("同步状态") {
            detailRow("更新状态", value: module.state.title, icon: statusIcon)
            detailRow("创建时间", value: module.createdAt.formatted(date: .long, time: .standard), icon: "calendar")
            detailRow("上次更新", value: module.lastUpdatedAt?.formatted(date: .long, time: .standard) ?? "从未更新", icon: "clock")
            detailRow("来源检查", value: module.sourceCheckedAt?.formatted(date: .long, time: .standard) ?? "尚未检查", icon: "dot.radiowaves.left.and.right")
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
        if model.settings.publishToGitHub {
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
        if model.settings.publishToLocal, module.publishesStandalone {
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
                            .foregroundStyle(.red)
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
                    .foregroundStyle(.orange)
            }
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
        guard module.storageLocation == .local else { return nil }
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

    private var iconSourceDescription: String {
        if module.customIconURL != nil {
            return "自定义图标（仅展示）"
        }
        if module.iconURL != nil {
            return "来源元数据（仅展示）"
        }
        return "默认图标"
    }

    private var iconURLDisplay: String? {
        module.customIconURL ?? module.iconURL
    }

    private var sourceAddressDisplay: String {
        let sourceURL = module.effectiveOriginalSourceURL
        if let url = URL(string: sourceURL), url.isFileURL {
            return url.path
        }
        return sourceURL.removingPercentEncoding ?? sourceURL
    }

    private var sourceAddressCopyValue: String {
        let sourceURL = module.effectiveOriginalSourceURL
        if let url = URL(string: sourceURL), url.isFileURL {
            return url.path
        }
        return sourceURL
    }

    private var statusIcon: String {
        switch module.state {
        case .never: "circle"
        case .updating: "arrow.triangle.2.circlepath"
        case .current: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
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
