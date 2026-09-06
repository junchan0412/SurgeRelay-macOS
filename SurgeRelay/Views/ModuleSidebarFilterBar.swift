import SwiftUI

struct ModuleSidebarFilterBar: View {
    @Binding var selection: ModuleFilter
    @Binding var sortOrder: ModuleSortOrder
    let counts: [ModuleFilter: Int]
    let resultCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("模块库").font(.system(size: 13, weight: .semibold))
                Text("\(resultCount)").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                Spacer(minLength: 0)
                filterMenu
                sortMenu
            }
            HStack(spacing: 5) {
                ForEach([ModuleFilter.all, .updatable, .attention]) { filter in chip(filter) }
            }
            if ![ModuleFilter.all, .updatable, .attention].contains(selection) {
                HStack {
                    Text("筛选：\(selection.title)").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("清除") { selection = .all }.font(.system(size: 12)).buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func chip(_ filter: ModuleFilter) -> some View {
        Button { selection = filter } label: {
            HStack(spacing: 4) {
                Text(filter == .attention ? "待处理" : filter.title)
                Text("\(counts[filter, default: 0])").monospacedDigit().opacity(0.75)
            }
            .font(.system(size: 11, weight: selection == filter ? .semibold : .regular))
            .lineLimit(1)
            .foregroundStyle(selection == filter ? Design.Palette.accent : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(selection == filter ? Design.Palette.accent.opacity(0.12) : Color.primary.opacity(0.035), in: .rect(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("筛选：\(filter.title)（\(counts[filter, default: 0]) 个模块）")
        .accessibilityAddTraits(selection == filter ? .isSelected : [])
    }

    private var filterMenu: some View {
        Menu {
            Button("全部") { selection = .all }
            ForEach(ModuleFilterGroup.allCases) { group in
                Section(group.title) {
                    ForEach(ModuleFilter.allCases.filter { $0.group == group }) { filter in
                        Button { selection = filter } label: {
                            Label(filter.title, systemImage: selection == filter ? "checkmark" : filter.systemImage)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease").frame(width: 22, height: 24)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("筛选模块").accessibilityLabel("筛选模块")
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
    }
}
