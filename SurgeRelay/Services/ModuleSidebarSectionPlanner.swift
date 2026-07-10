import Foundation

struct ModuleSidebarSection: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var systemImage: String
    var modules: [RelayModule]
}

enum ModuleSidebarSectionPlanner {
    static func sections(for modules: [RelayModule]) -> [ModuleSidebarSection] {
        var attention: [RelayModule] = []
        var local: [RelayModule] = []
        var remote: [RelayModule] = []
        var github: [RelayModule] = []
        var uncategorized: [RelayModule] = []

        for module in modules {
            if needsAttention(module) {
                attention.append(module)
            } else if !hasValidSource(module) {
                uncategorized.append(module)
            } else if module.storageLocation == .local {
                local.append(module)
            } else if module.publishesStandalone {
                github.append(module)
            } else {
                remote.append(module)
            }
        }

        return [
            ModuleSidebarSection(
                id: "attention",
                title: "需要处理",
                systemImage: "exclamationmark.triangle",
                modules: attention
            ),
            ModuleSidebarSection(
                id: "local",
                title: "本地模块",
                systemImage: "folder",
                modules: local
            ),
            ModuleSidebarSection(
                id: "remote",
                title: "远程模块",
                systemImage: "link",
                modules: remote
            ),
            ModuleSidebarSection(
                id: "github",
                title: "GitHub 模块",
                systemImage: "cloud",
                modules: github
            ),
            ModuleSidebarSection(
                id: "uncategorized",
                title: "未分类",
                systemImage: "link.badge.plus",
                modules: uncategorized
            )
        ]
        .filter { !$0.modules.isEmpty }
    }

    private static func needsAttention(_ module: RelayModule) -> Bool {
        module.state == .failed || module.hasOverrideConflict
    }

    private static func hasValidSource(_ module: RelayModule) -> Bool {
        module.initialSource != .invalid && module.hasValidUpdateSource
    }
}
