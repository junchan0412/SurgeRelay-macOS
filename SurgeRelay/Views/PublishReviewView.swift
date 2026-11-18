import SwiftUI

struct PublishReviewView: View {
    @Environment(AppModel.self) private var model
    let preview: PublishPreview

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                "发布预览",
                subtitle: preview.targetDescription,
                systemImage: "square.and.arrow.up"
            ) {
                MetadataPill("\(preview.activeFiles.count) 个有效文件")
            }

            ScrollView {
                PublishPreviewSummaryView(preview: preview)
                    .padding(20)
            }
            .background(Design.Palette.canvas)

            SheetActionFooter {
                Button("取消") { model.dismissPendingPublishPreview() }
                    .disabled(model.isWorking)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(preview.destination == .gitHub ? "确认发布" : "删除旧文件") {
                    Task { await model.confirmPendingPublish() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking || !preview.hasChanges)
            }
        }
        .frame(width: 620, height: 520)
        .interactiveDismissDisabled(model.isWorking)
    }
}

private struct PublishPreviewSummaryView: View {
    let preview: PublishPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !preview.issues.isEmpty {
                DetailInfoSection("发布前提示") {
                    ForEach(preview.issues) { issue in
                        Label("\(issue.filePath):\(issue.line) · \(issue.message)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Design.Palette.warning)
                            .padding(.vertical, 6)
                    }
                }
            }

            if preview.hasChanges {
                if !preview.changedFiles.isEmpty {
                    fileListSection("将上传 / 写入", files: preview.changedFiles, isDestructive: false)
                }
                if !preview.deletedFiles.isEmpty {
                    fileListSection("将删除", files: preview.deletedFiles, isDestructive: true)
                }
            } else {
                ContentUnavailableView("没有文件变化", systemImage: "checkmark.circle", description: Text("目标位置已与当前模块产物一致。"))
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .detailCard()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fileListSection(_ title: String, files: [String], isDestructive: Bool) -> some View {
        DetailInfoSection("\(title)（\(files.count)）") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(files.prefix(12)), id: \.self) { file in
                    HStack(spacing: 6) {
                        Image(systemName: isDestructive ? "minus.circle.fill" : "plus.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(isDestructive ? Design.Palette.warning : Design.Palette.success)
                        Text(file)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if files.count > 12 {
                    Text("另有 \(files.count - 12) 个文件…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            .padding(.vertical, 8)
        }
    }
}
