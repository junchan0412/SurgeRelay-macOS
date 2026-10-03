import SwiftUI

struct SettingsWorkspacesView: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkspaceController.self) private var workspaces
    @State private var showsNameDialog = false
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var showsTemplates = false
    @State private var errorMessage: String?

    var body: some View {
        SettingsForm {
            SettingsSection("工作区") {
                Text("每次只运行一个工作区。模块、仓库、凭据、草稿、版本历史和缓存分别保存。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(workspaces.registry.workspaces) { workspace in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: workspace.id == model.workspaceID ? "checkmark.circle.fill" : "folder")
                            .foregroundStyle(workspace.id == model.workspaceID ? Design.Palette.accent : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(workspace.name).fontWeight(.medium)
                            Text(workspace.configurationDirectory.path)
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button("重命名") { editingID = workspace.id; name = workspace.name; showsNameDialog = true }
                            .disabled(model.isWorking || workspaces.isSwitching)
                        if workspace.id != model.workspaceID {
                            Button("切换") {
                                Task {
                                    do { try await workspaces.switchWorkspace(to: workspace.id) }
                                    catch { errorMessage = error.localizedDescription }
                                }
                            }
                            .disabled(workspaces.isSwitching || model.workActivity.isActive && !model.workActivity.canCancel)
                        }
                    }
                    .padding(.vertical, 8)
                }
                Button("新建工作区…", systemImage: "plus") { editingID = nil; name = ""; showsNameDialog = true }
                    .disabled(workspaces.isSwitching || model.workActivity.isActive && !model.workActivity.canCancel)
            }
            SettingsSection("模块模板") {
                Text("模板仅保存格式、分类、相对输出位置和常用转换选项；创建时需要补填来源。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("管理当前工作区的模板…") { showsTemplates = true }
            }
        }
        .alert(editingID == nil ? "新建工作区" : "重命名工作区", isPresented: $showsNameDialog) {
            TextField("工作区名称", text: $name)
            Button("取消", role: .cancel) {}
            Button(editingID == nil ? "新建并切换" : "保存") {
                Task {
                    do {
                        if let editingID { try workspaces.renameWorkspace(id: editingID, name: name) }
                        else { try await workspaces.createWorkspace(name: name) }
                    } catch { errorMessage = error.localizedDescription }
                }
            }
        } message: { Text(editingID == nil ? "创建独立的空工作区，不复制当前模块或凭据。" : "名称变化不移动任何文件。") }
        .sheet(isPresented: $showsTemplates) { ModuleTemplatesView().environment(model) }
        .alert("无法完成工作区操作", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }
}
