import Foundation

struct ModuleArgumentUpdatePlan: Equatable, Sendable {
    var overrides: [String: String]
    var statusMessage: String
}

enum ModuleArgumentPlanner {
    static func setOverride(
        module: RelayModule,
        key: String,
        value: String,
        defaultValue: String
    ) -> ModuleArgumentUpdatePlan? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextStored: String? = normalized == defaultValue ? nil : normalized
        guard module.argumentOverrides[key] != nextStored else { return nil }

        var overrides = module.argumentOverrides
        if let nextStored {
            overrides[key] = nextStored
        } else {
            overrides.removeValue(forKey: key)
        }
        return ModuleArgumentUpdatePlan(
            overrides: overrides,
            statusMessage: "已更新 \(module.name) 的模块参数"
        )
    }

    static func resetOverrides(module: RelayModule) -> ModuleArgumentUpdatePlan? {
        guard !module.argumentOverrides.isEmpty else { return nil }
        return ModuleArgumentUpdatePlan(
            overrides: [:],
            statusMessage: "已恢复 \(module.name) 的默认参数"
        )
    }
}
