import AppKit
import SwiftUI

struct SettingsWorkspacesView: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkspaceController.self) private var workspaces
    @State private var showsNameDialog = false
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var showsTemplates = false
    @State private var errorMessage: String?
    @State private var migrationWorkspace: WorkspaceDescriptor?
    @State private var migrationDestination: URL?
    @State private var migratingWorkspaceID: UUID?

    var body: some View {
        SettingsForm {
            SettingsSection("工作区") {
                ForEach(workspaces.registry.workspaces) { workspace in
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: workspace.id == model.workspaceID ? "checkmark.circle.fill" : "square.stack.3d.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(workspace.id == model.workspaceID ? Design.Palette.accent : .secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(workspace.name)
                                    .font(.system(size: 13, weight: .semibold))
                                if workspace.id == model.workspaceID {
                                    MetadataPill("当前活跃", tint: Design.Palette.accent)
                                }
                            }
                            Text("配置：\(workspace.configurationDirectory.path)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Text("缓存：\(workspace.cacheDirectory.path)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 6) {
                            if workspace.id != model.workspaceID {
                                Button("切换") {
                                    Task {
                                        do { try await workspaces.switchWorkspace(to: workspace.id) }
                                        catch { errorMessage = error.localizedDescription }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(workspaces.isSwitching || migratingWorkspaceID != nil || model.workActivity.isActive && !model.workActivity.canCancel)
                            }
                            Button("重命名") { editingID = workspace.id; name = workspace.name; showsNameDialog = true }
                                .controlSize(.small)
                                .disabled(model.isWorking || workspaces.isSwitching || migratingWorkspaceID != nil)
                            Button(migratingWorkspaceID == workspace.id ? "迁移中…" : "迁移…") {
                                chooseMigrationDirectory(for: workspace)
                            }
                            .controlSize(.small)
                            .disabled(workspaces.isSwitching || migratingWorkspaceID != nil || model.workActivity.isActive && !model.workActivity.canCancel)
                            .accessibilityIdentifier("workspace.migrate.\(workspace.id.uuidString.lowercased())")
                        }
                    }
                    .padding(.vertical, 8)
                }

                HStack {
                    Text("每个工作区独立保存模块、凭据、草稿与缓存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("新建工作区…", systemImage: "plus") { editingID = nil; name = ""; showsNameDialog = true }
                        .controlSize(.small)
                        .disabled(workspaces.isSwitching || migratingWorkspaceID != nil || model.workActivity.isActive && !model.workActivity.canCancel)
                }
                .padding(.vertical, 6)
            }

            SettingsSection("模块模板") {
                HStack {
                    Text("模板保存格式、分类、相对输出路径与常用转换选项，新建模块时可快速套用。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("管理模板…") { showsTemplates = true }
                        .controlSize(.small)
                }
                .padding(.vertical, 8)
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
        .alert("迁移工作区", isPresented: Binding(
            get: { migrationWorkspace != nil && migrationDestination != nil },
            set: { if !$0 { migrationWorkspace = nil; migrationDestination = nil } }
        )) {
            Button("取消", role: .cancel) { migrationWorkspace = nil; migrationDestination = nil }
            Button("迁移") { migrateWorkspace() }
        } message: {
            if let workspace = migrationWorkspace, let destination = migrationDestination {
                Text("将“\(workspace.name)”的完整数据移动到：\n\(destination.path)\n\n工作区数据会先保存，迁移完成后使用新目录。")
            }
        }
        .alert("无法完成工作区操作", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func chooseMigrationDirectory(for workspace: WorkspaceDescriptor) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择用于保存工作区配置与缓存的目录。"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        migrationWorkspace = workspace
        migrationDestination = destination
    }

    private func migrateWorkspace() {
        guard let workspace = migrationWorkspace, let destination = migrationDestination else { return }
        migrationWorkspace = nil
        migrationDestination = nil
        migratingWorkspaceID = workspace.id
        Task { @MainActor in
            defer { migratingWorkspaceID = nil }
            do { try await workspaces.migrateWorkspace(id: workspace.id, to: destination) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
