import AppKit
import SwiftUI

struct ModuleDetailSummaryHeader: View {
    @Environment(AppModel.self) private var model
    let module: RelayModule
    let localOutput: LocalModuleOutputSnapshot?
    let onEdit: () -> Void
    var onOpenPreview: () -> Void = {}
    var onShowLint: () -> Void = {}
    var onShowVersionHistory: () -> Void = {}
    var onShowTemplateSave: () -> Void = {}
    var onCompareSync: (() -> Void)? = nil

    private var source: URL? { URL(string: module.updateSourceURL) }
    private var isNative: Bool {
        source.map { module.outputFormat.isNativeOutput(for: $0, sourceFormat: module.sourceFormat) } ?? false
    }

    private var outputTitle: String { module.displayStorageLocationTitle }
    private var outputDetail: String {
        module.hasLocalStorageTarget ? localOutput?.message ?? "正在检查本地文件…" : module.publishedRelativePath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    ModuleIconView(module: module, size: 48)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(module.name)
                            .font(.system(size: 20, weight: .bold))
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .help(module.name)

                        HStack(spacing: 6) {
                            StatusPill(state: module.state)
                            MetadataPill(module.outputFormat.title, tint: Design.Palette.accent)
                            MetadataPill(module.initialSource.title, systemImage: module.initialSource.systemImage)
                            if !module.category.isEmpty {
                                MetadataPill(module.category, systemImage: "tag")
                            }
                            if let date = module.lastUpdatedAt {
                                Text("更新于 \(date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .help(date.formatted(date: .long, time: .standard))
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        primaryActions
                        secondaryActions
                        Spacer(minLength: 4)
                        moreMenu
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            primaryActions
                            Spacer(minLength: 0)
                            moreMenu
                        }
                        HStack(spacing: 8) {
                            secondaryActions
                        }
                    }
                }
                .controlSize(.regular)

                if !model.updateAdmission(for: module).isAccepted && !model.isWorking {
                    Label(model.updateAdmission(for: module).message, systemImage: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)

            Rectangle()
                .fill(Design.Separator.rowColor)
                .frame(height: 1)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    flowStep(
                        "来源",
                        symbol: module.initialSource.systemImage,
                        value: source?.isFileURL == true ? "本地源文件" : source?.host() ?? "尚未配置",
                        detail: module.sourceFormatDisplayTitle
                    )
                    verticalDivider
                    flowStep(
                        "转换引擎",
                        symbol: "arrow.triangle.2.circlepath",
                        value: isNative ? "原生直通" : "Script-Hub",
                        detail: isNative ? "\(module.outputFormat.title) 原生兼容" : "转换为 \(module.outputFormat.title)"
                    )
                    verticalDivider
                    flowStep(
                        "产物去向",
                        symbol: module.displayStorageLocationSystemImage,
                        value: outputTitle,
                        detail: outputDetail
                    )
                }
                VStack(alignment: .leading, spacing: 10) {
                    flowStep(
                        "来源",
                        symbol: module.initialSource.systemImage,
                        value: source?.isFileURL == true ? "本地源文件" : source?.host() ?? "尚未配置",
                        detail: module.sourceFormatDisplayTitle
                    )
                    flowStep(
                        "转换引擎",
                        symbol: "arrow.triangle.2.circlepath",
                        value: isNative ? "原生直通" : "Script-Hub",
                        detail: isNative ? "\(module.outputFormat.title) 原生兼容" : "转换为 \(module.outputFormat.title)"
                    )
                    flowStep(
                        "产物去向",
                        symbol: module.displayStorageLocationSystemImage,
                        value: outputTitle,
                        detail: outputDetail
                    )
                }
                .padding(.vertical, 8)
            }
            .background(Design.Palette.elevated.opacity(0.35))
        }
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.large, style: .continuous))
        .detailCard(radius: Design.Radius.large)
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(Design.Separator.rowColor)
            .frame(width: 1)
            .padding(.vertical, 10)
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

    @ViewBuilder
    private var secondaryActions: some View {
        Button("查看内容", systemImage: "curlybraces", action: onOpenPreview)
            .buttonStyle(.bordered)

        Button("版本历史", systemImage: "clock.arrow.circlepath", action: onShowVersionHistory)
            .buttonStyle(.bordered)
            .disabled(model.isWorking)

        Button("发布检查", systemImage: "checkmark.shield", action: onShowLint)
            .buttonStyle(.bordered)
            .disabled(model.isWorking)
    }

    private var moreMenu: some View {
        Menu {
            Button("发布此模块", systemImage: "square.and.arrow.up") {
                Task { _ = await model.publishModules(moduleIDs: [module.id]) }
            }
            .disabled(model.isWorking)

            if module.hasLocalStorageTarget {
                Button("在访达中显示", systemImage: "folder") {
                    revealInFinder()
                }
            }

            if let onCompareSync {
                Button("比较本地与 GitHub…", systemImage: "arrow.left.arrow.right", action: onCompareSync)
                    .disabled(model.isWorking)
            }

            Divider()

            Button("拷贝更新地址", systemImage: "link") {
                copyToPasteboard(module.updateSourceURL)
            }
            .disabled(module.updateSourceURL.isEmpty)

            Button("拷贝输出路径", systemImage: "doc.on.doc") {
                copyToPasteboard(module.publishedRelativePath)
            }
            .disabled(module.publishedRelativePath.isEmpty)

            Divider()

            Button("保存为模块模板…", systemImage: "square.on.square", action: onShowTemplateSave)
                .disabled(model.isWorking)
        } label: {
            Label("更多操作", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderedButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多模块操作")
    }

    private func flowStep(_ title: String, symbol: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Design.Palette.accent)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(detail)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func revealInFinder() {
        let root = model.settings.localModuleDirectory(for: module.outputFormat)
        guard !root.isEmpty else { return }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent(module.publishedRelativePath)
        let folderURL = fileURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else if FileManager.default.fileExists(atPath: folderURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([folderURL])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([rootURL])
        }
    }
}
