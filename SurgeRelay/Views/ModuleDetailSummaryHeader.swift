import SwiftUI

struct ModuleDetailSummaryHeader: View {
    @Environment(AppModel.self) private var model
    let module: RelayModule
    let combinedModuleEnabled: Bool
    let onEdit: () -> Void

    private var source: URL? { URL(string: module.updateSourceURL) }
    private var isNative: Bool { source.map { module.sourceFormat.isNativeSurgeModule(for: $0) } ?? false }
    private var contributesToCombined: Bool {
        ModuleRefreshPlanner.contributesToCombined(module, combinedModuleEnabled: combinedModuleEnabled)
    }

    private var outputTitle: String {
        if module.publishesStandalone { return module.displayStorageLocationTitle }
        return contributesToCombined ? "总模块" : "模块缓存"
    }

    private var outputDetail: String {
        if module.publishesStandalone { return module.publishedRelativePath }
        return contributesToCombined ? "参与合并输出，未独立发布" : "未开启独立发布"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 18) {
                ModuleIconView(module: module, size: 60)
                VStack(alignment: .leading, spacing: 8) {
                    Text(module.name)
                        .font(.system(size: 28, weight: .bold))
                        .lineLimit(3).textSelection(.enabled)
                        .help(module.name)
                    Text([module.initialSource.title, module.category].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                StatusPill(state: module.state).fixedSize()
                if let date = module.lastUpdatedAt {
                    Text("更新于 \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .help(date.formatted(date: .long, time: .standard))
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        primaryActions
                        Spacer(minLength: 0)
                        TextCopyButton(text: module.updateSourceURL, title: "拷贝更新地址")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) { primaryActions }
                        TextCopyButton(text: module.updateSourceURL, title: "拷贝更新地址")
                    }
                }
                .controlSize(.large)
                if !model.updateAdmission(for: module).isAccepted && !model.isWorking {
                    Text(model.updateAdmission(for: module).message)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 120), spacing: 0), count: 3), alignment: .leading, spacing: 18) {
                flowStep("来源", symbol: module.initialSource.systemImage,
                         value: source?.isFileURL == true ? "本地源文件" : source?.host() ?? "尚未配置",
                         detail: module.sourceFormatDisplayTitle)
                flowStep("转换", symbol: "arrow.triangle.2.circlepath",
                         value: isNative ? "原生 Surge" : "Script-Hub",
                         detail: isNative ? "保留原生模块格式" : "转换为 Surge 模块")
                flowStep("输出", symbol: module.publishesStandalone ? module.standaloneStorageSystemImage
                         : contributesToCombined ? "square.stack.3d.up" : "internaldrive",
                         value: outputTitle, detail: outputDetail)
            }
            .padding(.vertical, 20)
            .detailCard(radius: Design.Radius.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var primaryActions: some View {
        Button(module.state == .updating ? "正在更新…" : "更新模块", systemImage: "arrow.clockwise") {
            model.startUpdate(moduleID: module.id)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.updateAdmission(for: module).isAccepted)
        .help(model.updateAdmission(for: module).message)
        .accessibilityIdentifier("module-detail.update")
        Button("编辑配置", systemImage: "slider.horizontal.3", action: onEdit)
            .buttonStyle(.bordered)
            .accessibilityIdentifier("module-detail.edit")
    }

    private func flowStep(_ title: String, symbol: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Design.Palette.accent)
            Text(value).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle).help(value)
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).help(detail)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
