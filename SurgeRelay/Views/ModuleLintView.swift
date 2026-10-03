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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("模块发布前检查").font(.headline)
                Spacer()
                if moduleID != nil {
                    Button("重新检查") { Task { await check() } }.disabled(isLoading || model.isWorking)
                }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("检查配置结构、重复项和受管脚本资源；不联网验证外部 URL，也不保证规则实际命中效果。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if isLoading {
                ProgressView("正在检查…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !hasCompletedCheck {
                ContentUnavailableView("检查尚未完成，请重试", systemImage: "exclamationmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if issues.isEmpty {
                ContentUnavailableView("未发现结构或资源问题", systemImage: "checkmark.seal")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(issues) { issue in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline) {
                                    Label(issue.severity.title, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(issue.severity == .error ? Design.Palette.error : Design.Palette.warning)
                                    Text("\(issue.filePath) · 第 \(issue.line) 行")
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Text(issue.message).textSelection(.enabled)
                                if let related = issue.relatedLine {
                                    Text("关联位置：第 \(related) 行")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                    }
                }
            }
            HStack {
                Text(!hasCompletedCheck ? "检查未完成。" : hasErrors ? "错误必须修复后才能发布。" : issues.isEmpty ? "本次检查通过。" : "提醒不会阻止发布；请核对后决定是否继续。")
                    .font(.caption).foregroundStyle(hasErrors ? Design.Palette.error : .secondary)
                Spacer()
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
        .padding(20)
        .frame(minWidth: 720, minHeight: 460)
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
        }
        catch { errorMessage = error.localizedDescription }
    }
}
