import Foundation

enum ModuleFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case updatable
    case nonUpdatable
    case enabled
    case disabled
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
        case .enabled: "已启用"
        case .disabled: "已禁用"
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
        case .enabled: "checkmark.circle"
        case .disabled: "circle"
        case .local: "folder"
        case .github: "cloud"
        case .attention: "exclamationmark.triangle"
        case .uncategorized: "link.badge.plus"
        }
    }

    func matches(_ module: RelayModule, combinedModuleEnabled: Bool) -> Bool {
        switch self {
        case .all:
            true
        case .updatable:
            module.hasRemoteUpdateSource
        case .nonUpdatable:
            !module.hasRemoteUpdateSource
        case .enabled:
            module.isEnabled
        case .disabled:
            !module.isEnabled
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
