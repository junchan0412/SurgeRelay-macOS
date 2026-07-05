import Foundation

struct ModulePreviewSavePlan: Equatable, Sendable {
    var shouldWriteOverride: Bool
    var overrideContent: String
    var module: RelayModule
    var statusMessage: String
}

struct ModulePreviewRestorePlan: Equatable, Sendable {
    var module: RelayModule
    var statusMessage: String
}

struct ModulePreviewConflictPlan: Equatable, Sendable {
    var module: RelayModule
    var statusMessage: String
}

enum ModulePreviewEditPlanner {
    static func savePlan(
        module: RelayModule,
        namedContent: String,
        currentContent: String?,
        convertedContent: String?,
        automaticallyPublish: Bool
    ) -> ModulePreviewSavePlan {
        guard currentContent != namedContent else {
            return ModulePreviewSavePlan(
                shouldWriteOverride: false,
                overrideContent: namedContent,
                module: module,
                statusMessage: "内容没有变化"
            )
        }

        var nextModule = module
        if let convertedContent {
            nextModule.overrideBaseHash = hash(convertedContent)
            nextModule.hasOverrideConflict = false
        }
        return ModulePreviewSavePlan(
            shouldWriteOverride: true,
            overrideContent: namedContent,
            module: nextModule,
            statusMessage: automaticallyPublish ? "已写入 \(module.name)，等待合并发布" : "已写入 \(module.name)"
        )
    }

    static func restorePlan(module: RelayModule, automaticallyPublish: Bool) -> ModulePreviewRestorePlan {
        var nextModule = module
        nextModule.overrideBaseHash = nil
        nextModule.hasOverrideConflict = false
        return ModulePreviewRestorePlan(
            module: nextModule,
            statusMessage: automaticallyPublish
                ? "已恢复 \(module.name) 的转换结果，等待合并发布"
                : "已恢复 \(module.name) 的转换结果"
        )
    }

    static func acceptConflictPlan(
        module: RelayModule,
        convertedContent: String
    ) -> ModulePreviewConflictPlan {
        var nextModule = module
        nextModule.overrideBaseHash = hash(convertedContent)
        nextModule.hasOverrideConflict = false
        return ModulePreviewConflictPlan(
            module: nextModule,
            statusMessage: "已保留 \(module.name) 的本地编辑"
        )
    }

    private static func hash(_ content: String) -> String {
        Data(content.utf8).sha256String
    }
}
