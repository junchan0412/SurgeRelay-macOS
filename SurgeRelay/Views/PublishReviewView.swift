import SwiftUI

struct PublishReviewView: View {
    @Environment(AppModel.self) private var model
    let preview: PublishPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("发布预览").font(.title2.bold())
            ScrollView { PublishPreviewSummaryView(preview: preview) }
            HStack {
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
        .padding(24)
        .frame(width: 620, height: 540)
        .interactiveDismissDisabled(model.isWorking)
    }
}

private struct PublishPreviewSummaryView: View {
    let preview: PublishPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            detail("目标", value: preview.targetDescription)
            detail("结果清单", value: "\(preview.activeFiles.count) 个文件")
            ForEach(preview.issues) { issue in
                Label("\(issue.filePath):\(issue.line) · \(issue.message)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Design.Palette.warning)
            }
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
                .foregroundStyle(isDestructive ? Design.Palette.warning : .primary)
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
