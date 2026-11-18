import SwiftUI

struct ModuleLintView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let moduleID: UUID?
    private let onContinue: (() -> Void)?
    @State private var issues: [ModuleLintIssue]
    @State private var isLoading = false
    @State private var hasCompletedCheck = false
    @State private var errorMessage: String?

    init(moduleID: UUID) {
        self.moduleID = moduleID
        onContinue = nil
        _issues = State(initialValue: [])
    }

    init(issues: [ModuleLintIssue], onContinue: (() -> Void)? = nil) {
        moduleID = nil
        self.onContinue = onContinue
        _issues = State(initialValue: issues)
        _hasCompletedCheck = State(initialValue: true)
    }

    private var hasErrors: Bool { issues.contains { $0.severity == .error } }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                "模块发布前检查",
                subtitle: "静态检查配置段落、重复规则与受管脚本资源，不联网验证外部 URL。",
                systemImage: "checkmark.shield"
            ) {
                if moduleID != nil {
                    Button("重新检查") { Task { await check() } }
                        .controlSize(.small)
                        .disabled(isLoading || model.isWorking)
                }
            }

            Group {
                if isLoading {
                    ProgressView("正在检查…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !hasCompletedCheck {
                    ContentUnavailableView("检查尚未完成，请重试", systemImage: "exclamationmark.circle")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if issues.isEmpty {
                    ContentUnavailableView("未发现结构或资源问题", systemImage: "checkmark.seal", description: Text("此模块配置格式与受管资源引用正常。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            GroupedCardStack(dividerInset: 26) {
                                ForEach(issues) { issue in
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                            .foregroundStyle(issue.severity == .error ? Design.Palette.error : Design.Palette.warning)
                                            .padding(.top, 2)
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 8) {
                                                Text(issue.severity.title)
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundStyle(issue.severity == .error ? Design.Palette.error : Design.Palette.warning)
                                                Text("\(issue.filePath) · 第 \(issue.line) 行")
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                            }
                                            Text(issue.message)
                                                .font(.system(size: 12))
                                                .textSelection(.enabled)
                                            if let related = issue.relatedLine {
                                                Text("关联位置：第 \(related) 行")
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 8)
                                }
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .background(Design.Palette.canvas)

            SheetActionFooter {
                Text(!hasCompletedCheck ? "检查未完成" : hasErrors ? "错误修复后才可继续发布" : issues.isEmpty ? "本次检查通过" : "警告不会阻止发布，请核对后继续")
                    .font(.caption)
                    .foregroundStyle(hasErrors ? Design.Palette.error : .secondary)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let onContinue {
                    Button(issues.isEmpty ? "继续发布" : "确认继续发布") {
                        dismiss()
                        onContinue()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(hasErrors || isLoading || !hasCompletedCheck)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 440)
        .task { if moduleID != nil { await check() } }
        .alert("无法完成检查", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func check() async {
        guard let moduleID else { return }
        isLoading = true
        hasCompletedCheck = false
        defer { isLoading = false }
        do {
            issues = try await model.checkModuleContent(moduleID: moduleID)
            hasCompletedCheck = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
