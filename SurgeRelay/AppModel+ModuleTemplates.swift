import Foundation

@MainActor
extension AppModel {
    func saveModuleTemplate(moduleID: UUID, name: String) async throws {
        guard !isWorking, workspaceIsActive else { throw PreviewContentSaveError.busy }
        guard let module = modules.first(where: { $0.id == moduleID }) else { throw RelayError.invalidOutput("模块已移除。") }
        moduleTemplates.append(try ModuleTemplatePlanner.template(from: module, name: name))
        enqueueConfiguration(moduleTemplates, fileName: "module-templates.json")
        try await flushPersistence()
        statusMessage = "模块设置已保存为模板；来源地址和凭据未包含"
    }

    func deleteModuleTemplate(id: UUID) async throws {
        guard !isWorking, workspaceIsActive else { throw PreviewContentSaveError.busy }
        moduleTemplates.removeAll { $0.id == id }
        enqueueConfiguration(moduleTemplates, fileName: "module-templates.json")
        try await flushPersistence()
    }
}
