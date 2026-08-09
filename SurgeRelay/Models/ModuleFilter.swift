import Foundation

/// 侧边栏模块筛选维度。
enum ModuleFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case updatable
    case nonUpdatable
    case failed
    case neverUpdated
    case includedInCombined
    case excludedFromCombined
    case local
    case github
    case subscribed
    case remoteSource
    case selfAuthored
    case standalone
    case cachedOnly
    case attention
    case overrideConflict
    case uncategorized

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .updatable: "可更新"
        case .nonUpdatable: "不可更新"
        case .failed: "更新失败"
        case .neverUpdated: "尚未更新"
        case .includedInCombined: "参与总模块"
        case .excludedFromCombined: "不参与总模块"
        case .local: "本地"
        case .github: "GitHub"
        case .subscribed: "订阅来源"
        case .remoteSource: "远程来源"
        case .selfAuthored: "自写模块"
        case .standalone: "独立发布"
        case .cachedOnly: "仅缓存"
        case .attention: "需要处理"
        case .overrideConflict: "覆盖冲突"
        case .uncategorized: "未分类"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.stack.3d.up"
        case .updatable: "arrow.triangle.2.circlepath"
        case .nonUpdatable: "pause.circle"
        case .failed: "xmark.octagon"
        case .neverUpdated: "circle.dashed"
        case .includedInCombined: "shippingbox.fill"
        case .excludedFromCombined: "shippingbox"
        case .local: "folder"
        case .github: "cloud"
        case .subscribed: "arrow.down.doc"
        case .remoteSource: "link"
        case .selfAuthored: "pencil.and.outline"
        case .standalone: "doc.badge.gearshape"
        case .cachedOnly: "internaldrive"
        case .attention: "exclamationmark.triangle"
        case .overrideConflict: "exclamationmark.arrow.triangle.2.circlepath"
        case .uncategorized: "link.badge.plus"
        }
    }

    /// 显示在快捷栏上、最常用的筛选。
    static let quickPresets: [ModuleFilter] = [.all, .updatable, .nonUpdatable, .attention]

    /// 当前筛选是否属于快捷栏预设。
    var isQuickPreset: Bool {
        Self.quickPresets.contains(self)
    }

    /// 筛选所属分组（用于在“更多筛选”菜单中分组展示）。
    var group: ModuleFilterGroup? {
        switch self {
        case .all:
            nil
        case .updatable, .nonUpdatable, .failed, .neverUpdated:
            .updateState
        case .subscribed, .remoteSource, .selfAuthored:
            .source
        case .local, .github:
            .storage
        case .includedInCombined, .excludedFromCombined:
            .combined
        case .standalone, .cachedOnly:
            .behavior
        case .attention, .overrideConflict, .uncategorized:
            .status
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
        case .failed:
            module.state == .failed
        case .neverUpdated:
            module.state == .never
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
        case .subscribed:
            module.initialSource.isSubscribed
        case .remoteSource:
            module.initialSource.isRemote
        case .selfAuthored:
            module.initialSource == .selfAuthored
        case .standalone:
            module.publishesStandalone
        case .cachedOnly:
            !module.publishesStandalone
        case .attention:
            module.state == .failed || module.hasOverrideConflict
        case .overrideConflict:
            module.hasOverrideConflict
        case .uncategorized:
            module.initialSource == .invalid || !module.hasValidUpdateSource
        }
    }
}

/// 筛选的分组分类，用于在筛选菜单中组织条目。
enum ModuleFilterGroup: String, CaseIterable, Identifiable, Sendable {
    case updateState
    case source
    case storage
    case combined
    case behavior
    case status

    var id: String { rawValue }

    var title: String {
        switch self {
        case .updateState: "更新状态"
        case .source: "来源"
        case .storage: "存放位置"
        case .combined: "总模块"
        case .behavior: "发布行为"
        case .status: "状态"
        }
    }
}

/// 侧边栏模块排序方式。
enum ModuleSortOrder: String, CaseIterable, Identifiable, Sendable {
    case nameAsc
    case nameDesc
    case lastUpdated
    case createdAt
    case statusFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nameAsc: "名称 A→Z"
        case .nameDesc: "名称 Z→A"
        case .lastUpdated: "最近更新"
        case .createdAt: "最近创建"
        case .statusFirst: "按状态优先"
        }
    }

    var systemImage: String {
        switch self {
        case .nameAsc: "arrow.up.arrow.down"
        case .nameDesc: "arrow.down.arrow.up"
        case .lastUpdated: "clock"
        case .createdAt: "calendar"
        case .statusFirst: "list.number"
        }
    }

    func sorted(_ modules: [RelayModule]) -> [RelayModule] {
        switch self {
        case .nameAsc:
            modules.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .nameDesc:
            modules.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending
            }
        case .lastUpdated:
            modules.sorted {
                ($0.lastUpdatedAt ?? .distantPast) > ($1.lastUpdatedAt ?? .distantPast)
            }
        case .createdAt:
            modules.sorted { $0.createdAt > $1.createdAt }
        case .statusFirst:
            modules.sorted {
                let lhs = Self.statusRank($0.state)
                let rhs = Self.statusRank($1.state)
                if lhs != rhs { return lhs < rhs }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    private static func statusRank(_ state: ModuleUpdateState) -> Int {
        switch state {
        case .failed: 0
        case .never: 1
        case .updating: 2
        case .current: 3
        }
    }
}