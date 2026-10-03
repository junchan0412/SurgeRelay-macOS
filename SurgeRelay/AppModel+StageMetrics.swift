import Foundation

@MainActor
extension AppModel {
    func setWorkStage(_ stage: WorkStage?, moduleID: UUID, moduleName: String, detail: String? = nil) {
        if let stage {
            activeStageProgress[moduleID] = WorkStageProgress(moduleID: moduleID, moduleName: moduleName, stage: stage, startedAt: .now, detail: detail)
        } else {
            activeStageProgress.removeValue(forKey: moduleID)
        }
        guard stageProgressTask == nil else { return }
        stageProgressTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self else { return }
            stageProgressTask = nil
            guard workActivity.isActive else { return }
            let stages = activeStageProgress.values.sorted { $0.moduleID.uuidString < $1.moduleID.uuidString }
            workActivity.activeStages = stages.isEmpty ? nil : Array(stages.prefix(ModuleUpdatePipeline.maximumConcurrency))
        }
    }
}
