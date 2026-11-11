import AppKit
import SwiftUI

@MainActor
struct ConversionToolsView: View {
    @Environment(AppModel.self) private var model
    @State private var inputRevision = 0

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("转换工具").font(.system(size: 32, weight: .bold))
                    Text("把规则或脚本转换为所选客户端的文件，直接复制或保存结果。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ModuleEditorSection("转换类型") {
                    Picker("转换类型", selection: $model.conversionToolDraft.kind) {
                        Text("规则集").tag(ConversionToolKind.ruleSet)
                        Text("脚本").tag(ConversionToolKind.script)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("conversion-tools.kind")
                    ModuleEditorControlRow("输出客户端", icon: "arrow.triangle.2.circlepath") {
                        Picker("输出客户端", selection: $model.conversionToolDraft.outputFormat) {
                            ForEach(ModuleOutputFormat.allCases) { format in Text(format.title).tag(format) }
                        }.labelsHidden().accessibilityIdentifier("conversion-tools.output-format")
                    }
                    if model.conversionToolDraft.kind == .script {
                        ModuleEditorControlRow("脚本源客户端", icon: "doc.text") {
                            Picker("脚本源客户端", selection: $model.conversionToolDraft.sourceFormat) {
                                Text("Quantumult X").tag(ModuleSourceFormat.quantumultX)
                                Text("Surge").tag(ModuleSourceFormat.surge)
                                Text("Loon").tag(ModuleSourceFormat.loon)
                            }.labelsHidden()
                        }
                    } else {
                        ModuleEditorControlRow("规则输出", icon: "list.bullet") {
                            Picker("规则输出", selection: $model.conversionToolDraft.ruleOutputStyle) {
                                Text("完整规则集").tag(RuleOutputStyle.ruleSet)
                                if [.surge, .egern, .stash].contains(model.conversionToolDraft.outputFormat) {
                                    Text("仅域名").tag(RuleOutputStyle.domainSet)
                                    Text("非域名规则").tag(RuleOutputStyle.nonDomainRules)
                                }
                            }.labelsHidden()
                        }
                        if model.conversionToolDraft.outputFormat == .quantumultX {
                            ModuleEditorTextFieldRow(title: "规则策略", icon: "arrow.triangle.branch", text: $model.conversionToolDraft.policy,
                                prompt: "REJECT、DIRECT 或已有策略名称")
                        }
                    }
                    ModuleEditorTextFieldRow(title: "输出文件名", icon: "doc", text: $model.conversionToolDraft.outputName, prompt: "Converted")
                }
                ModuleEditorSection("来源") {
                    HStack {
                        TextField("HTTP/HTTPS 或本地文件地址", text: Binding(
                            get: { model.conversionToolDraft.sourceURL },
                            set: { model.conversionToolDraft.sourceURL = $0; if !$0.isEmpty { model.conversionToolDraft.sourceText = "" } }
                        )).textFieldStyle(.roundedBorder).accessibilityIdentifier("conversion-tools.source-url")
                        Button("选择文件…", action: chooseSourceFile)
                    }
                    Text("或直接粘贴内容").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { model.conversionToolDraft.sourceText },
                        set: { model.conversionToolDraft.sourceText = $0; if !$0.isEmpty { model.conversionToolDraft.sourceURL = "" } }
                    ))
                    .font(.system(.body, design: .monospaced)).frame(minHeight: 180)
                    .accessibilityIdentifier("conversion-tools.source-text")
                }
                DisclosureGroup("高级转换选项") { advancedOptions.padding(.top, 12) }
                    .font(.system(size: 14, weight: .medium))
                HStack(spacing: 12) {
                    Button("转换", action: convert).buttonStyle(.borderedProminent)
                        .disabled(model.isWorking).accessibilityIdentifier("conversion-tools.convert")
                    if model.isWorking {
                        Text(model.workActivity.title).font(.callout).foregroundStyle(.secondary)
                    }
                    if model.workActivity.kind.rawValue == "convertingTool", model.workActivity.canCancel {
                        Button(model.workCancellationRequested ? "正在取消…" : "取消转换") { _ = model.cancelCurrentWork() }
                            .disabled(model.workCancellationRequested)
                    }
                }
                if let error = model.nativeToolError {
                    Text(error).font(.callout).foregroundStyle(Design.Palette.error)
                        .textSelection(.enabled).accessibilityIdentifier("conversion-tools.error")
                }
                if let result = model.nativeToolResult {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(result.fileName).font(.headline).textSelection(.enabled)
                            Spacer()
                            Button("复制结果") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(result.content, forType: .string)
                            }
                            Button("保存文件…") { saveResult(result) }
                        }
                        TextEditor(text: .constant(result.content)).font(.system(.body, design: .monospaced))
                            .frame(minHeight: 240).accessibilityIdentifier("conversion-tools.result")
                    }.padding(20).detailCard(radius: Design.Radius.large)
                }
            }
            .frame(maxWidth: 940, alignment: .leading).padding(32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Design.Palette.canvas)
        .accessibilityIdentifier("workspace.conversion-tools")
        .onChange(of: model.conversionToolDraft) { _, _ in
            inputRevision += 1
            model.nativeToolResult = nil
            model.nativeToolError = nil
        }
        .onChange(of: model.conversionToolDraft.outputFormat) { _, format in
            if ![.surge, .egern, .stash].contains(format) { model.conversionToolDraft.ruleOutputStyle = .ruleSet }
            if model.conversionToolDraft.sourceFormat != .quantumultX || format == .quantumultX { model.conversionToolDraft.wrapResponse = false }
        }
        .onChange(of: model.conversionToolDraft.sourceFormat) { _, format in
            if format != .quantumultX { model.conversionToolDraft.wrapResponse = false }
        }
    }

    private var advancedOptions: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 16) {
            if model.conversionToolDraft.kind == .ruleSet {
                ModuleEditorTextFieldRow(title: "释放注释关键字", icon: "line.3.horizontal.decrease", text: $model.conversionToolDraft.includeKeywords, prompt: "多项使用 + 分隔")
                ModuleEditorTextFieldRow(title: "删除关键字", icon: "line.3.horizontal.decrease", text: $model.conversionToolDraft.excludeKeywords, prompt: "多项使用 + 分隔")
                Toggle("添加 no-resolve", isOn: $model.conversionToolDraft.noResolve)
                ModuleEditorTextFieldRow(title: "SNI", icon: "network", text: $model.conversionToolDraft.sni, prompt: "服务器名称")
            } else {
                Toggle("仅转换兼容性", isOn: $model.conversionToolDraft.compatibilityOnly)
                if model.conversionToolDraft.sourceFormat == .quantumultX, model.conversionToolDraft.outputFormat != .quantumultX {
                    Toggle("响应脚本封装", isOn: $model.conversionToolDraft.wrapResponse)
                }
                textArea("脚本前置代码", text: $model.conversionToolDraft.prependScript)
            }
            textArea("来源请求 Header", text: $model.conversionToolDraft.requestHeaders)
            textArea("转换前处理代码", text: $model.conversionToolDraft.evalScriptOriginal)
            textArea("转换后处理代码", text: $model.conversionToolDraft.evalScriptModified)
            ModuleEditorTextFieldRow(title: "转换前处理代码 URL", icon: "link", text: $model.conversionToolDraft.evalURLOriginal, prompt: "https://example.com/process.js")
            ModuleEditorTextFieldRow(title: "转换后处理代码 URL", icon: "link", text: $model.conversionToolDraft.evalURLModified, prompt: "https://example.com/process.js")
        }
    }

    private func textArea(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text).font(.system(.body, design: .monospaced)).frame(minHeight: 80)
        }
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
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try Data(result.content.utf8).write(to: url, options: .atomic) }
            catch { model.nativeToolError = error.localizedDescription }
        }
    }
}
