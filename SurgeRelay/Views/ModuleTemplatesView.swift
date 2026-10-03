import SwiftUI

struct ModuleTemplatesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTemplate: ModuleTemplate?
    @State private var deletingTemplate: ModuleTemplate?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(model.workspaceName) · 模块模板").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("在模块详情中保存模板。来源地址、请求头、参数值、脚本正文和凭据不会复制到模板。")
                .font(.caption).foregroundStyle(.secondary)
            if model.moduleTemplates.isEmpty {
                ContentUnavailableView("尚无模板", systemImage: "square.on.square")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.moduleTemplates) { template in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(template.name).fontWeight(.medium)
                            Text(template.sourceFormat.title + (template.category.isEmpty ? "" : " · " + template.category))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("从模板创建") { selectedTemplate = template }.disabled(model.isWorking)
                        Button("移除", role: .destructive) { deletingTemplate = template }.disabled(model.isWorking)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 660, minHeight: 430)
        .sheet(item: $selectedTemplate) { template in
            ModuleEditorView(module: nil, initialDraft: ModuleTemplatePlanner.draft(from: template)).environment(model)
        }
        .confirmationDialog("移除此模板？", isPresented: Binding(get: { deletingTemplate != nil }, set: { if !$0 { deletingTemplate = nil } })) {
            Button("移除模板", role: .destructive) {
                guard let template = deletingTemplate else { return }
                Task {
                    do { try await model.deleteModuleTemplate(id: template.id) }
                    catch { errorMessage = error.localizedDescription }
                    deletingTemplate = nil
                }
            }
        } message: { Text("已经创建的模块不会受到影响。") }
        .alert("无法完成模板操作", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }
}
