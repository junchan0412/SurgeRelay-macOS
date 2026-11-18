import SwiftUI

struct ModuleTemplatesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTemplate: ModuleTemplate?
    @State private var deletingTemplate: ModuleTemplate?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                "\(model.workspaceName) · 模块模板",
                subtitle: "复用格式、分类、目录与转换控制；不复制来源地址或凭据。",
                systemImage: "square.on.square"
            )

            Group {
                if model.moduleTemplates.isEmpty {
                    ContentUnavailableView("尚无模板", systemImage: "square.on.square", description: Text("可在任意模块的“更多操作”菜单中将其保存为模板。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        GroupedCardStack(dividerInset: 0) {
                            ForEach(model.moduleTemplates) { template in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(template.name)
                                            .font(.system(size: 13, weight: .semibold))
                                        Text(template.sourceFormat.title + " → " + template.outputFormat.title + (template.category.isEmpty ? "" : " · " + template.category))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("从模板新建…") { selectedTemplate = template }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                        .disabled(model.isWorking)
                                    Button("移除", role: .destructive) { deletingTemplate = template }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .disabled(model.isWorking)
                                }
                                .padding(.vertical, 8)
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .background(Design.Palette.canvas)

            SheetActionFooter {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
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
