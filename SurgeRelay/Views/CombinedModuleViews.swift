import AppKit
import SwiftUI

struct CombinedModuleRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image("SummaryIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .clipShape(summaryIconShape)
                .overlay {
                    summaryIconShape
                        .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text("Surge Relay 汇总")
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text("\(model.moduleSummary.enabledCount) 个来源 · 总模块订阅")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 5)
    }

    private var summaryIconShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 32 * ModuleIconView.cornerRadiusRatio, style: .continuous)
    }
}

struct CombinedModuleDetailView: View {
    @Environment(AppModel.self) private var model

    private var summary: ModuleCollectionSummary {
        model.moduleSummary
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summaryHeader
                contentSection
                outputSection
                latestPublishSection
                publishPreviewSection
            }
            .frame(maxWidth: 760, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var summaryHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            Image("SummaryIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 56 * ModuleIconView.cornerRadiusRatio, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Text("Surge Relay 汇总")
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { summaryPills }
                    VStack(alignment: .leading, spacing: 6) { summaryPills }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.24), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var summaryPills: some View {
        metadataPill("\(summary.enabledCount) 个来源", systemImage: "shippingbox")
        if model.settings.publishToLocal {
            metadataPill("本地发布", systemImage: "folder")
        }
        if model.settings.publishToGitHub {
            metadataPill("GitHub 发布", systemImage: "cloud")
        }
        if summary.hasFailures {
            metadataPill("\(summary.failedCount) 个失败", systemImage: "exclamationmark.triangle", isWarning: true)
        }
    }

    private var contentSection: some View {
        detailSection("汇总内容") {
            detailRow("包含来源", value: "\(summary.enabledCount) / \(summary.totalCount)", icon: "shippingbox")
            detailRow("独立模块", value: "\(summary.standaloneCount) 个同时单独发布", icon: "doc.badge.gearshape")
            detailRow("最新更新", value: summary.latestUpdatedAt?.formatted(date: .long, time: .standard) ?? "尚未更新", icon: "clock")
            detailRow(
                "总模块文件",
                value: FilenameSanitizer.sgmoduleName(from: model.settings.combinedModuleFileName),
                icon: "square.stack.3d.up",
                monospaced: true
            )
        }
    }

    private var outputSection: some View {
        detailSection("总模块输出") {
            if model.settings.publishToLocal {
                if let localURL = model.combinedLocalFileURL {
                    detailRow("文件位置", value: localURL.path, icon: "doc", monospaced: true, copyValue: localURL.path)
                } else {
                    Label("等待本地模块根目录配置。", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            if model.settings.publishToGitHub {
                if let rawURL = model.combinedRawURL {
                    detailRow("GitHub 订阅", value: rawURL.absoluteString, icon: "link", monospaced: true, copyValue: rawURL.absoluteString)
                } else {
                    Label("完成 GitHub 发布配置后，这里会显示稳定订阅地址。", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var latestPublishSection: some View {
        if model.settings.publishToGitHub, let publish = model.latestGitHubPublish {
            detailSection("最近 GitHub 发布") {
                detailRow("提交", value: publish.commitDisplay, icon: "arrow.triangle.branch")
                detailRow("时间", value: publish.date.formatted(date: .long, time: .standard), icon: "clock")
                detailRow("变更", value: publish.fileSummary, icon: "doc.on.doc")
                if let commitURL = publish.commitURL.flatMap(URL.init(string:)) {
                    Link(destination: commitURL) {
                        Label("打开 Commit", systemImage: "arrow.up.right.square")
                    }
                }
                if publish.changedFileCount > 0 {
                    DisclosureGroup("文件清单") {
                        publishFileList("上传/更新", files: publish.publishedFiles, systemImage: "arrow.up.doc")
                        publishFileList("删除", files: publish.deletedFiles, systemImage: "trash", isDestructive: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var publishPreviewSection: some View {
        let preview = relevantPublishPreview
        if model.settings.publishToGitHub || preview != nil {
            detailSection("发布与清理") {
                if model.settings.publishToGitHub {
                    Button("预览发布…", systemImage: "square.and.arrow.up") {
                        Task { await model.previewPublish() }
                    }
                    .disabled(model.isWorking || !model.settings.github.isConfigured || model.githubToken.isEmpty)
                }

                if let preview {
                    PublishPreviewSummaryView(preview: preview)
                    HStack {
                        Button(preview.destination == .gitHub ? "确认发布" : "删除旧文件", systemImage: "checkmark.circle") {
                            Task { await model.confirmPendingPublish() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isWorking || !preview.hasChanges)

                        Button("取消预览", role: .cancel) {
                            model.dismissPendingPublishPreview()
                        }
                        .disabled(model.isWorking)
                    }
                } else if model.settings.publishToGitHub {
                    Label("发布前可预览新增、更新和删除的文件；包含删除项时会要求确认。", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var relevantPublishPreview: PublishPreview? {
        guard let preview = model.pendingPublishPreview else { return nil }
        if preview.destination == .gitHub { return model.settings.publishToGitHub ? preview : nil }
        if preview.destination == .local { return model.settings.publishToLocal ? preview : nil }
        return nil
    }

    private func metadataPill(_ title: String, systemImage: String, isWarning: Bool = false) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(isWarning ? .orange : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.45), in: Capsule())
    }

    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        DetailInfoSection(title, content: content)
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

private struct PublishPreviewSummaryView: View {
    let preview: PublishPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            detail("目标", value: preview.targetDescription)
            detail("结果清单", value: "\(preview.activeFiles.count) 个文件")
            if preview.hasChanges {
                if !preview.changedFiles.isEmpty {
                    fileList("将上传/写入", files: preview.changedFiles)
                }
                if !preview.deletedFiles.isEmpty {
                    fileList("将删除", files: preview.deletedFiles, isDestructive: true)
                }
            } else {
                Label("没有文件变化", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.medium))
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    private func fileList(_ title: String, files: [String], isDestructive: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("\(title) \(files.count) 个文件", systemImage: isDestructive ? "trash" : "arrow.up.doc")
                .font(.caption.weight(.medium))
                .foregroundStyle(isDestructive ? .orange : .primary)
            ForEach(Array(files.prefix(8)), id: \.self) { file in
                Text(file)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if files.count > 8 {
                Text("另有 \(files.count - 8) 个文件")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private func publishFileList(
    _ title: String,
    files: [String],
    systemImage: String,
    isDestructive: Bool = false
) -> some View {
    Group {
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Label("\(title) \(files.count) 个文件", systemImage: systemImage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isDestructive ? .orange : .primary)
                ForEach(Array(files.prefix(10)), id: \.self) { file in
                    Text(file)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if files.count > 10 {
                    Text("另有 \(files.count - 10) 个文件")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}
