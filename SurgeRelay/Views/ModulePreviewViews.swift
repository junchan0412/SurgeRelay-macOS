import SwiftUI

/// Inline, editable preview of a single module's converted result. Replaces the
/// old preview window; lives in the detail pane's “预览” tab.
struct ModulePreviewPane: View {
    @Environment(AppModel.self) private var model
    let module: RelayModule
    @State private var text = ""
    @State private var savedText = ""
    @State private var isLoading = true
    @State private var isWriting = false
    @State private var errorMessage: String?
    @State private var showsComparison = false

    private var currentModule: RelayModule {
        model.modules.first(where: { $0.id == module.id }) ?? module
    }

    var body: some View {
        VStack(spacing: 0) {
            if currentModule.hasOverrideConflict {
                HStack(spacing: 10) {
                    Label("上游内容已变化，请确认本地编辑", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("比较…") { showsComparison = true }
                    Button("保留本地编辑") {
                        Task { await model.acceptOverrideConflict(moduleID: module.id) }
                    }
                }
                .padding(10)
                .background(.orange.opacity(0.08))
                Divider()
            }
            ModuleCodeTextView(
                text: $text,
                isEditable: !isLoading,
                modules: [module],
                selectedModuleID: module.id
            )
            .ignoresSafeArea(.container, edges: .top)

            Divider()
            HStack(spacing: 12) {
                Button("恢复") { restore() }
                    .disabled(isWriting || isLoading)
                if !isLoading, text != savedText {
                    Text("有尚未写入的修改")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("保存") { write() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(isWriting || isLoading || text == savedText)
            }
            .padding(12)
        }
        .task(id: module.id) { await load() }
        .alert("无法完成操作", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showsComparison) {
            OverrideComparisonView(module: currentModule)
                .environment(model)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let content = try await model.previewContent(for: module)
            text = content
            savedText = content
        } catch {
            errorMessage = "无法预览转换结果：\(error.localizedDescription)"
        }
    }

    private func write() {
        isWriting = true
        Task {
            defer { isWriting = false }
            do {
                try await model.savePreviewContent(text, for: module)
                savedText = text
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func restore() {
        isWriting = true
        Task {
            defer { isWriting = false }
            do {
                let restored = try await model.restorePreviewContent(for: module)
                text = restored
                savedText = restored
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct OverrideComparisonView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let module: RelayModule
    @State private var upstream = ""
    @State private var local = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("上游与本地编辑").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            HSplitView {
                comparisonColumn("最新上游", text: upstream)
                comparisonColumn("当前本地编辑", text: local)
            }
        }
        .frame(minWidth: 920, minHeight: 560)
        .task {
            do {
                async let upstreamValue = model.convertedPreviewContent(for: module)
                async let localValue = model.previewContent(for: module)
                (upstream, local) = try await (upstreamValue, localValue)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert("无法载入比较", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("好", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }

    private func comparisonColumn(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption.weight(.semibold)).padding(10)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
        }
    }
}

/// Inline, read-only preview of the merged final module.
struct CombinedPreviewPane: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var enabledModules: [RelayModule] {
        ModuleRefreshPlanner.combinedContributorModules(
            in: model.modules,
            combinedModuleEnabled: model.settings.combinedModuleEnabled
        )
    }

    private var reloadToken: String {
        "\(model.settings.combinedModuleEnabled)-" + enabledModules.map { "\($0.id.uuidString)-\($0.contentHash ?? "")" }.joined()
    }

    var body: some View {
        ModuleCodeTextView(
            text: .constant(text),
            isEditable: false,
            modules: enabledModules,
            selectedModuleID: nil
        )
        .ignoresSafeArea(.container, edges: .top)
        .overlay {
            if !isLoading, text.isEmpty {
                ContentUnavailableView("没有可预览的内容", systemImage: "doc.text.magnifyingglass")
            }
        }
        .task(id: reloadToken) { await load() }
        .alert("无法完成操作", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            text = try await model.combinedPreviewContent()
        } catch {
            errorMessage = "无法预览最终模块：\(error.localizedDescription)"
        }
    }
}
