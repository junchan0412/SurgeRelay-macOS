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
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("模块库")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(resultCount)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("当前显示 \(resultCount) 个模块")
                Spacer(minLength: 0)
                filterMenu
                sortMenu
            }

            HStack(spacing: 4) {
                ForEach([ModuleFilter.all, .updatable, .attention]) { filter in
                    chip(filter)
                }
            }

            if selection != .all || hasSearchQuery {
                HStack(spacing: 6) {
                    Image(systemName: selection == .all ? "magnifyingglass" : selection.systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Design.Palette.accent)
                    Text(activeFilterSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("重置") {
                        selection = .all
                        searchText = ""
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
                    .help("清除筛选与搜索，显示所有模块")
                    .accessibilityLabel("清除筛选与搜索")
                    .accessibilityIdentifier("modules.reset-filters")
                }
                .padding(.top, 1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("modules.filters")
    }

    private var activeFilterSummary: String {
        if selection != .all && hasSearchQuery {
            return "\(selection.title) · “\(searchText)”"
        }
        if hasSearchQuery {
            return "搜索：“\(searchText)”"
        }
        return selection.title
    }

    private func chip(_ filter: ModuleFilter) -> some View {
        let count = counts[filter, default: 0]
        let isSelected = selection == filter
        let isUrgent = filter == .attention && count > 0
        let activeColor = isUrgent && isSelected ? Design.Palette.warning : Design.Palette.accent

        let textColor: Color = isSelected ? activeColor : (isUrgent ? Design.Palette.warning : .secondary)
        let countColor: Color = isSelected ? activeColor : (isUrgent ? Design.Palette.warning : Color.secondary.opacity(0.75))

        return Button { selection = filter } label: {
            HStack(spacing: 3) {
                Text(filter == .attention ? "待处理" : filter.title)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(countColor)
            }
            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            .lineLimit(1)
            .foregroundStyle(textColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                isSelected ? activeColor.opacity(0.14) : Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? activeColor.opacity(0.45) : .clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("筛选：\(filter.title)（\(count) 个模块）")
        .accessibilityLabel("\(filter.title)，\(count) 个模块")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 12))
                .frame(width: 20, height: 20)
                .foregroundStyle(selection == .all ? Color.secondary : Design.Palette.accent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("筛选：\(selection.title)")
        .accessibilityLabel("筛选模块")
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
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11))
                .frame(width: 20, height: 20)
                .foregroundStyle(sortOrder == .nameAsc ? Color.secondary : Design.Palette.accent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("排序：\(sortOrder.title)")
        .accessibilityLabel("模块排序")
        .accessibilityValue(sortOrder.title)
        .accessibilityIdentifier("modules.sort-menu")
    }
}
