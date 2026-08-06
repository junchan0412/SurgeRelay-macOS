import Foundation

enum ModuleFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case updatable
    case nonUpdatable
    case includedInCombined
    case excludedFromCombined
    case local
    case github
    case attention
    case uncategorized

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .updatable: "可更新"
        case .nonUpdatable: "不可更新"
        case .includedInCombined: "参与总模块"
        case .excludedFromCombined: "不参与总模块"
        case .local: "本地"
        case .github: "GitHub"
        case .attention: "需要处理"
        case .uncategorized: "未分类"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.stack.3d.up"
        case .updatable: "arrow.triangle.2.circlepath"
        case .nonUpdatable: "pause.circle"
        case .includedInCombined: "shippingbox.fill"
        case .excludedFromCombined: "shippingbox"
        case .local: "folder"
        case .github: "cloud"
        case .attention: "exclamationmark.triangle"
        case .uncategorized: "link.badge.plus"
        }
    }

    static func counts(
        for modules: [RelayModule],
        combinedModuleEnabled: Bool
    ) -> [ModuleFilter: Int] {
        var result = Dictionary(uniqueKeysWithValues: allCases.map { ($0, 0) })
        for module in modules {
            for filter in allCases where filter.matches(
                module,
                combinedModuleEnabled: combinedModuleEnabled
            ) {
                result[filter, default: 0] += 1
            }
        }
        return result
    }

    func matches(_ module: RelayModule, combinedModuleEnabled: Bool) -> Bool {
        switch self {
        case .all:
            true
        case .updatable:
            ModuleRefreshPlanner.isUpdateable(
                module,
                combinedModuleEnabled: combinedModuleEnabled
            )
        case .nonUpdatable:
            !ModuleRefreshPlanner.isUpdateable(
                module,
                combinedModuleEnabled: combinedModuleEnabled
            )
        case .includedInCombined:
            ModuleRefreshPlanner.contributesToCombined(
                module,
                combinedModuleEnabled: combinedModuleEnabled
            )
        case .excludedFromCombined:
            !ModuleRefreshPlanner.contributesToCombined(
                module,
                combinedModuleEnabled: combinedModuleEnabled
            )
        case .local:
            module.storageLocation == .local
        case .github:
            module.storageLocation == .gitHub
        case .attention:
            module.state == .failed || module.hasOverrideConflict
        case .uncategorized:
            module.initialSource == .invalid || !module.hasValidUpdateSource
        }
    }
}
