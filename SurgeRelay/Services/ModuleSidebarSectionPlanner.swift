import Foundation

struct ModuleSidebarSection: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var systemImage: String
    var modules: [RelayModule]
}

enum ModuleSidebarSectionPlanner {
    static func sections(for modules: [RelayModule]) -> [ModuleSidebarSection] {
        [
            ModuleSidebarSection(
                id: "attention",
                title: "需要处理",
                systemImage: "exclamationmark.triangle",
                modules: modules.filter(needsAttention)
            ),
            ModuleSidebarSection(
                id: "local",
                title: "本地模块",
                systemImage: "folder",
                modules: modules.filter { module in
                    !needsAttention(module) &&
                        module.storageLocation == .local &&
                        module.sourceOrigin != .invalid
                }
            ),
            ModuleSidebarSection(
                id: "github",
                title: "GitHub 模块",
                systemImage: "cloud",
                modules: modules.filter { module in
                    !needsAttention(module) &&
                        module.storageLocation == .gitHub &&
                        module.sourceOrigin != .invalid
                }
            ),
            ModuleSidebarSection(
                id: "uncategorized",
                title: "未分类",
                systemImage: "link.badge.plus",
                modules: modules.filter { module in
                    !needsAttention(module) && module.sourceOrigin == .invalid
                }
            )
        ]
        .filter { !$0.modules.isEmpty }
    }

    private static func needsAttention(_ module: RelayModule) -> Bool {
        module.state == .failed || module.hasOverrideConflict
    }
}
