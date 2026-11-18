import AppKit
import SwiftUI

@MainActor
struct ConversionToolsView: View {
    @Environment(AppModel.self) private var model
    @State private var inputRevision = 0
    @State private var showsAdvancedOptions = false
    @State private var copiedResult = false

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                configurationBar
                if showsAdvancedOptions {
                    advancedOptionsCard
                }
                workbenchPanes
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Design.Palette.canvas)
        .accessibilityIdentifier("workspace.conversion-tools")
        .onChange(of: model.conversionToolDraft) { _, _ in
            inputRevision += 1
            model.nativeToolResult = nil
            model.nativeToolError = nil
            copiedResult = false
        }
        .onChange(of: model.conversionToolDraft.outputFormat) { _, format in
            if ![.surge, .egern, .stash].contains(format) { model.conversionToolDraft.ruleOutputStyle = .ruleSet }
            if model.conversionToolDraft.sourceFormat != .quantumultX || format == .quantumultX { model.conversionToolDraft.wrapResponse = false }
        }
        .onChange(of: model.conversionToolDraft.sourceFormat) { _, format in
            if format != .quantumultX { model.conversionToolDraft.wrapResponse = false }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("转换工具")
                    .font(.system(size: 22, weight: .bold))
                Text("单次转换规则集或独立脚本，直接对比输入与目标客户端产物。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle(isOn: $showsAdvancedOptions.animation(.snappy(duration: 0.18))) {
                Label("高级转换选项", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.button)
            .controlSize(.regular)
        }
    }

    private var configurationBar: some View {
        @Bindable var model = model
        return GroupedCardStack(dividerInset: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    kindPicker
                    Divider().frame(height: 20)
                    formatPickers
                    Spacer(minLength: 4)
                    outputNameField
                }
                .padding(.vertical, 6)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        kindPicker
                        Spacer(minLength: 0)
                        outputNameField
                    }
                    formatPickers
                }
                .padding(.vertical, 8)
            }

            if model.conversionToolDraft.kind == .ruleSet && model.conversionToolDraft.outputFormat == .quantumultX {
                ModuleEditorTextFieldRow(
                    title: "规则策略",
                    icon: "arrow.triangle.branch",
                    text: $model.conversionToolDraft.policy,
                    prompt: "REJECT、DIRECT 或已有策略名称"
                )
            }
        }
    }

    private var kindPicker: some View {
        @Bindable var model = model
        return Picker("转换类型", selection: $model.conversionToolDraft.kind) {
            Text("规则集").tag(ConversionToolKind.ruleSet)
            Text("脚本").tag(ConversionToolKind.script)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 150)
        .accessibilityIdentifier("conversion-tools.kind")
    }

    private var formatPickers: some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            if model.conversionToolDraft.kind == .script {
                HStack(spacing: 6) {
                    Text("源格式")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Picker("脚本源客户端", selection: $model.conversionToolDraft.sourceFormat) {
                        Text("Quantumult X").tag(ModuleSourceFormat.quantumultX)
                        Text("Surge").tag(ModuleSourceFormat.surge)
                        Text("Loon").tag(ModuleSourceFormat.loon)
                    }
                    .labelsHidden()
                    .frame(width: 132)
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                Text("目标")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("输出客户端", selection: $model.conversionToolDraft.outputFormat) {
                    ForEach(ModuleOutputFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .labelsHidden()
                .frame(width: 132)
                .accessibilityIdentifier("conversion-tools.output-format")
            }

            if model.conversionToolDraft.kind == .ruleSet {
                HStack(spacing: 6) {
                    Text("产物")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Picker("规则输出", selection: $model.conversionToolDraft.ruleOutputStyle) {
                        Text("完整规则集").tag(RuleOutputStyle.ruleSet)
                        if [.surge, .egern, .stash].contains(model.conversionToolDraft.outputFormat) {
                            Text("仅域名").tag(RuleOutputStyle.domainSet)
                            Text("非域名规则").tag(RuleOutputStyle.nonDomainRules)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 116)
                }
            }
        }
    }

    private var outputNameField: some View {
        @Bindable var model = model
        return HStack(spacing: 6) {
            Text("文件名")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Converted", text: $model.conversionToolDraft.outputName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
        }
    }

    private var workbenchPanes: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                inputPane
                    .frame(minWidth: 360, maxWidth: .infinity)
                outputPane
                    .frame(minWidth: 360, maxWidth: .infinity)
            }
            VStack(spacing: 14) {
                inputPane
                outputPane
            }
        }
    }

    private var inputPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label("输入来源", systemImage: "tray.and.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("粘贴") {
                    if let pasted = NSPasteboard.general.string(forType: .string), !pasted.isEmpty {
                        model.conversionToolDraft.sourceURL = ""
                        model.conversionToolDraft.sourceText = pasted
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("选择文件…", action: chooseSourceFile)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                if !model.conversionToolDraft.sourceURL.isEmpty || !model.conversionToolDraft.sourceText.isEmpty {
                    Button("清空") {
                        model.conversionToolDraft.sourceURL = ""
                        model.conversionToolDraft.sourceText = ""
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Design.Palette.surface)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("HTTP/HTTPS 地址或本地文件 URL（与下方正文二选一）", text: Binding(
                    get: { model.conversionToolDraft.sourceURL },
                    set: {
                        model.conversionToolDraft.sourceURL = $0
                        if !$0.isEmpty { model.conversionToolDraft.sourceText = "" }
                    }
                ))
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.plain)
                .accessibilityIdentifier("conversion-tools.source-url")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Design.Palette.elevated.opacity(0.45))

            Divider()

            TextEditor(text: Binding(
                get: { model.conversionToolDraft.sourceText },
                set: {
                    model.conversionToolDraft.sourceText = $0
                    if !$0.isEmpty { model.conversionToolDraft.sourceURL = "" }
                }
            ))
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Design.Palette.codeBackground)
            .frame(minHeight: 340)
            .accessibilityIdentifier("conversion-tools.source-text")

            Divider()

            HStack(spacing: 10) {
                if model.isWorking {
                    ProgressView().controlSize(.small)
                    Text(model.workActivity.title)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(inputSummaryText)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if model.workActivity.kind.rawValue == "convertingTool", model.workActivity.canCancel {
                    Button(model.workCancellationRequested ? "正在取消…" : "取消转换") {
                        _ = model.cancelCurrentWork()
                    }
                    .controlSize(.small)
                    .disabled(model.workCancellationRequested)
                }
                Button(action: convert) {
                    Label("执行转换", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking)
                .accessibilityIdentifier("conversion-tools.convert")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Design.Palette.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
        .detailCard()
    }

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label(model.nativeToolResult?.fileName ?? "转换结果", systemImage: "doc.badge.gearshape")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if let result = model.nativeToolResult {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.content, forType: .string)
                        withAnimation(.snappy(duration: 0.18)) { copiedResult = true }
                        Task {
                            try? await Task.sleep(for: .seconds(1.4))
                            withAnimation(.snappy(duration: 0.18)) { copiedResult = false }
                        }
                    } label: {
                        Label(copiedResult ? "已复制" : "复制结果", systemImage: copiedResult ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(copiedResult ? Design.Palette.success : nil)

                    Button {
                        saveResult(result)
                    } label: {
                        Label("保存文件…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Design.Palette.surface)

            Divider()

            if let error = model.nativeToolError {
                VStack(alignment: .leading, spacing: 10) {
                    Label("转换失败", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Design.Palette.error)
                    Text(error)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Design.Palette.error)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("conversion-tools.error")
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 382, alignment: .topLeading)
                .background(Design.Palette.codeBackground)
            } else if let result = model.nativeToolResult {
                TextEditor(text: .constant(result.content))
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Design.Palette.codeBackground)
                    .frame(minHeight: 382)
                    .accessibilityIdentifier("conversion-tools.result")

                Divider()

                HStack {
                    Text("\(result.outputFormat.title) · \(result.content.components(separatedBy: .newlines).count) 行")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(result.content.utf8.count), countStyle: .file))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Design.Palette.surface)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right.square")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.quaternary)
                    Text("等待转换输出")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("在左侧填写远程地址、选择文件或粘贴内容后点击“执行转换”。")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, minHeight: 422)
                .background(Design.Palette.codeBackground)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
        .detailCard()
    }

    private var inputSummaryText: String {
        if !model.conversionToolDraft.sourceURL.isEmpty {
            return "使用地址输入"
        }
        if !model.conversionToolDraft.sourceText.isEmpty {
            let lines = model.conversionToolDraft.sourceText.components(separatedBy: .newlines).count
            return "正文 \(lines) 行"
        }
        return "未输入来源"
    }

    private var advancedOptionsCard: some View {
        @Bindable var model = model
        return ModuleEditorSection("高级转换选项") {
            if model.conversionToolDraft.kind == .ruleSet {
                ModuleEditorTextFieldRow(title: "释放注释关键字", icon: "line.3.horizontal.decrease", text: $model.conversionToolDraft.includeKeywords, prompt: "多项使用 + 分隔")
                ModuleEditorTextFieldRow(title: "删除关键字", icon: "line.3.horizontal.decrease", text: $model.conversionToolDraft.excludeKeywords, prompt: "多项使用 + 分隔")
                ModuleEditorToggleRow(title: "添加 no-resolve", icon: "network.slash", isOn: $model.conversionToolDraft.noResolve)
                ModuleEditorTextFieldRow(title: "SNI", icon: "network", text: $model.conversionToolDraft.sni, prompt: "服务器名称")
            } else {
                ModuleEditorToggleRow(title: "仅转换兼容性", icon: "checkmark.shield", isOn: $model.conversionToolDraft.compatibilityOnly)
                if model.conversionToolDraft.sourceFormat == .quantumultX, model.conversionToolDraft.outputFormat != .quantumultX {
                    ModuleEditorToggleRow(title: "响应脚本封装", icon: "curlybraces", isOn: $model.conversionToolDraft.wrapResponse)
                }
                textArea("脚本前置代码", text: $model.conversionToolDraft.prependScript)
            }
            textArea("来源请求 Header", text: $model.conversionToolDraft.requestHeaders)
            textArea("转换前处理代码", text: $model.conversionToolDraft.evalScriptOriginal)
            textArea("转换后处理代码", text: $model.conversionToolDraft.evalScriptModified)
            ModuleEditorTextFieldRow(title: "转换前处理 URL", icon: "link", text: $model.conversionToolDraft.evalURLOriginal, prompt: "https://example.com/process.js")
            ModuleEditorTextFieldRow(title: "转换后处理 URL", icon: "link", text: $model.conversionToolDraft.evalURLModified, prompt: "https://example.com/process.js")
        }
    }

    private func textArea(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Design.Palette.codeBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Design.Palette.stroke, lineWidth: 1)
                }
                .frame(minHeight: 68)
        }
        .padding(.vertical, 6)
    }

    private func chooseSourceFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.conversionToolDraft.sourceText = ""
            model.conversionToolDraft.sourceURL = url.absoluteString
        }
    }

    private func convert() {
        let draft = model.conversionToolDraft
        let revision = inputRevision
        let workspaceID = model.workspaceID
        model.nativeToolResult = nil
        model.nativeToolError = nil
        Task { @MainActor in
            do {
                let result = try await model.convertTool(draft)
                guard workspaceID == model.workspaceID, model.workspaceIsActive, !model.isWorkspaceTransitioning,
                      revision == inputRevision, model.conversionToolDraft == draft else { return }
                model.nativeToolResult = result
            } catch {
                guard workspaceID == model.workspaceID, model.workspaceIsActive, !model.isWorkspaceTransitioning,
                      revision == inputRevision, model.conversionToolDraft == draft else { return }
                model.nativeToolError = error is CancellationError ? "转换已取消。" : error.localizedDescription
            }
        }
    }

    private func saveResult(_ result: ConversionToolResult) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = result.fileName
        let directory = model.settings.localModuleDirectory(for: result.outputFormat)
        if !directory.isEmpty { panel.directoryURL = URL(filePath: directory, directoryHint: .isDirectory) }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try Data(result.content.utf8).write(to: url, options: .atomic) }
            catch { model.nativeToolError = error.localizedDescription }
        }
    }
}
