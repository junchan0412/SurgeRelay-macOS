import SwiftUI

struct ModuleSidebarFilterBar: View {
    @Binding var selection: ModuleFilter
    @Binding var sortOrder: ModuleSortOrder
    @Binding var searchText: String
    let counts: [ModuleFilter: Int]
    let resultCount: Int

    private var hasSearchQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("模块库").font(.system(size: 13, weight: .semibold))
                Text("\(resultCount)").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityLabel("当前显示 \(resultCount) 个模块")
                Spacer(minLength: 0)
                filterMenu
                sortMenu
            }
            HStack(spacing: 5) {
                ForEach([ModuleFilter.all, .updatable, .attention]) { filter in chip(filter) }
            }
            if selection != .all || hasSearchQuery {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Label(selection.title, systemImage: selection.systemImage)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button("重置") {
                            selection = .all
                            searchText = ""
                        }
                        .buttonStyle(.borderless)
                        .help("清除筛选与搜索，显示所有模块")
                        .accessibilityLabel("清除筛选与搜索")
                        .accessibilityIdentifier("modules.reset-filters")
                    }
                    if hasSearchQuery {
                        Text("搜索：\(searchText)")
                            .lineLimit(1).truncationMode(.middle)
                            .help(searchText)
                    }
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("modules.filters")
    }

    private func chip(_ filter: ModuleFilter) -> some View {
        Button { selection = filter } label: {
            HStack(spacing: 4) {
                Text(filter == .attention ? "待处理" : filter.title)
                Text("\(counts[filter, default: 0])").monospacedDigit()
            }
            .font(.system(size: 11, weight: selection == filter ? .semibold : .regular))
            .lineLimit(1)
            .foregroundStyle(selection == filter ? Design.Palette.accent : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(selection == filter ? Design.Palette.accent.opacity(0.12) : Color.primary.opacity(0.035), in: .rect(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(selection == filter ? Design.Palette.accent.opacity(0.6) : .clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("筛选：\(filter.title)（\(counts[filter, default: 0]) 个模块）")
        .accessibilityLabel("\(filter.title)，\(counts[filter, default: 0]) 个模块")
        .accessibilityAddTraits(selection == filter ? .isSelected : [])
        .accessibilityIdentifier("modules.filter.\(filter.rawValue)")
    }

    private var filterMenu: some View {
        Menu {
            Button { selection = .all } label: {
                Label("全部（\(counts[.all, default: 0])）", systemImage: selection == .all ? "checkmark" : ModuleFilter.all.systemImage)
            }
            ForEach(ModuleFilterGroup.allCases) { group in
                Section(group.title) {
                    ForEach(ModuleFilter.allCases.filter { $0.group == group }) { filter in
                        Button { selection = filter } label: {
                            Label("\(filter.title)（\(counts[filter, default: 0])）",
                                  systemImage: selection == filter ? "checkmark" : filter.systemImage)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease").frame(width: 22, height: 24)
                .foregroundStyle(selection == .all ? Color.secondary : Design.Palette.accent)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("筛选：\(selection.title)").accessibilityLabel("筛选模块")
        .accessibilityValue(selection.title)
        .accessibilityIdentifier("modules.filter-menu")
    }

    private var sortMenu: some View {
        Menu {
            ForEach(ModuleSortOrder.allCases) { order in
                Button { sortOrder = order } label: {
                    Label(order.title, systemImage: sortOrder == order ? "checkmark" : order.systemImage)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down").frame(width: 22, height: 24)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("排序：\(sortOrder.title)").accessibilityLabel("模块排序")
        .accessibilityValue(sortOrder.title)
        .accessibilityIdentifier("modules.sort-menu")
    }
}
