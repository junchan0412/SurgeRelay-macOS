import Foundation

enum AutomaticPublishPlanner {
    static let noStandaloneModulesStatus = "没有开启独立发布的模块，已跳过 GitHub 自动发布"
    static let noStandaloneFilesStatus = "没有可自动发布的独立模块文件，已跳过 GitHub 自动发布"

    static func skippedAfterModuleUpdateStatus(contentChanged: Bool, failures: Int) -> String {
        let failureSuffix = failures > 0 ? "；\(failures) 个来源沿用上次成功版本" : ""
        if contentChanged {
            return "模块输出已更新\(failureSuffix)；没有开启独立发布的模块，已跳过 GitHub 自动发布"
        }
        return "模块内容未变化\(failureSuffix)；没有开启独立发布的模块，无需 GitHub 自动发布"
    }

    static func hasCachedStandaloneOutput(
        plan: PublishPlan,
        componentExists: @Sendable (UUID) async -> Bool
    ) async -> Bool {
        for module in plan.standaloneModules {
            if await componentExists(module.id) {
                return true
            }
        }
        return false
    }
}
