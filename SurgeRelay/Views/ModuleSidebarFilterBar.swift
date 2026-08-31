import SwiftUI

struct ModuleSidebarFilterBar: View {
    @Binding var selection: ModuleFilter
    @Binding var sortOrder: ModuleSortOrder
    let counts: [ModuleFilter: Int]
    let resultCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(ModuleFilter.quickPresets) { filter in
                    chip(filter)
                }
                if !selection.isQuickPreset {
                    activeChip(selection)
                }
                Spacer(minLength: 0)
                filterMenu
                sortMenu
            }
            .font(.caption)
            .padding(.horizontal, 2)

            HStack(spacing: 6) {
                Text("\(resultCount) 个模块")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if selection != .all {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { selection = .all }
                    } label: {
                        Label("清除筛选", systemImage: "xmark.circle.fill")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func chip(_ filter: ModuleFilter) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { selection = filter }
        } label: {
            Label {
                Text("\(filter.title) \(counts[filter, default: 0])")
            } icon: {
                Image(systemName: filter.systemImage)
            }
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                selection == filter
                    ? Color.accentColor.opacity(0.18)
                    : Color.primary.opacity(0.06),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        selection == filter
                            ? Color.accentColor.opacity(0.5)
                            : Color.primary.opacity(0.08),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == filter ? .isSelected : [])
    }

    private func activeChip(_ filter: ModuleFilter) -> some View {
        HStack(spacing: 4) {
            Label(filter.title, systemImage: filter.systemImage)
                .lineLimit(1)
            Button {
                withAnimation(.snappy(duration: 0.2)) { selection = .all }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("清除筛选")
        }
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.18), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
        }
        .accessibilityAddTraits(.isSelected)
    }

    private var filterMenu: some View {
        Menu {
            Button {
                withAnimation(.snappy(duration: 0.2)) { selection = .all }
            } label: {
                Label("全部", systemImage: selection == .all
                    ? "checkmark"
                    : ModuleFilter.all.systemImage)
            }
            Divider()
            ForEach(ModuleFilterGroup.allCases) { group in
                Section(group.title) {
                    ForEach(ModuleFilter.allCases.filter { $0.group == group }) { filter in
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { selection = filter }
                        } label: {
                            Label(filter.title, systemImage: selection == filter
                                ? "checkmark"
                                : filter.systemImage)
                        }
                    }
                }
            }
            Divider()
            Button(role: .destructive) {
                withAnimation(.snappy(duration: 0.2)) { selection = .all }
            } label: {
                Label("清除筛选", systemImage: "xmark.circle")
            }
            .disabled(selection == .all)
        } label: {
            Label(selection.isQuickPreset || selection == .all ? "筛选" : selection.title,
                  systemImage: "line.3.horizontal.decrease.circle")
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var sortMenu: some View {
        Menu {
            ForEach(ModuleSortOrder.allCases) { order in
                Button {
                    sortOrder = order
                } label: {
                    Label(order.title, systemImage: sortOrder == order
                        ? "checkmark"
                        : order.systemImage)
                }
            }
        } label: {
            Label(sortOrder.title, systemImage: sortOrder.systemImage)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
