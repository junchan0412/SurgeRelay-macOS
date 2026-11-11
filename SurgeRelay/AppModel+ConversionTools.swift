import Foundation

@MainActor
extension AppModel {
    func convertTool(_ draft: ConversionToolDraft) async throws -> ConversionToolResult {
        guard workspaceIsActive, !isWorkspaceTransitioning, !isWorking else { throw PreviewContentSaveError.busy }
        try ConversionToolService.validate(draft)
        beginWork(.convertingTool)
        synchronizationCompletedCount = 0
        synchronizationTotalCount = 0
        workActivity.title = draft.kind == .ruleSet ? "规则集转换" : "独立脚本转换"
        defer {
            conversionToolTask = nil
            endWork(.convertingTool)
        }
        let operation = Task { @MainActor in
            if ConversionToolService.requiresEngine(draft) {
                let name = draft.kind == .ruleSet ? "rule-parser.js" : "script-converter.js"
                if !(await engineStore.hasScript(named: name)) { await refreshScriptHubInternal() }
                try checkCurrentWorkCancellation()
                guard await engineStore.hasScript(named: name) else {
                    throw RelayError.invalidOutput(upstreamState.lastError ?? "转换引擎缺少 \(name)，请更新 Script-Hub 引擎。")
                }
            }
            statusMessage = "正在转换为 \(draft.outputFormat.title)…"
            return try await conversionToolService.convert(draft: draft)
        }
        conversionToolTask = operation
        do {
            let result = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
            try checkCurrentWorkCancellation()
            guard workspaceIsActive, !isWorkspaceTransitioning else { throw PreviewContentSaveError.changed }
            statusMessage = "已生成 \(result.fileName)"
            return result
        } catch {
            if !isCurrentWorkCancellation(error) { statusMessage = "转换失败：\(error.localizedDescription)" }
            throw error
        }
    }
}
