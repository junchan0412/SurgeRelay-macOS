import SwiftUI

struct ModuleDetailPaneView: View {
    @Environment(AppModel.self) private var model
    @Binding var searchText: String
    let editModule: (RelayModule) -> Void

    @State private var selectedTab: DetailTab = .info
    @State private var hasPresentedPreview = false

    private enum DetailTab: Hashable {
        case info
        case preview
    }

    private enum SelectionKind: Equatable {
        case combined
        case module(UUID)
    }

    private var selectedTabBinding: Binding<DetailTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                withAnimation(.snappy(duration: 0.22, extraBounce: 0.02)) {
                    selectedTab = newValue
                    if newValue == .preview {
                        hasPresentedPreview = true
                    }
                }
            }
        )
    }

    private var selectionKind: SelectionKind? {
        if model.settings.combinedModuleEnabled,
           model.selectedModuleID == AppModel.combinedModuleSelectionID {
            return .combined
        }
        if let id = model.selectedModuleID,
           model.modules.contains(where: { $0.id == id }) {
            return .module(id)
        }
        return nil
    }

    private var selectedModule: RelayModule? {
        guard case let .module(id) = selectionKind else { return nil }
        return model.modules.first(where: { $0.id == id })
    }

    var body: some View {
        Group {
            if let kind = selectionKind {
                detailContent(for: kind)
                    .id(kindID(kind))
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)).combined(with: .offset(x: 8)),
                        removal: .opacity.combined(with: .offset(x: -6))
                    ))
            } else {
                ContentUnavailableView("选择一个模块", systemImage: "sidebar.right")
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy(duration: 0.22), value: selectionKind.map(kindID))
        .searchable(text: $searchText, prompt: "搜索")
        .toolbar {
            ToolbarSpacer(.flexible)
            if selectionKind != nil {
                ToolbarItem {
                    Picker("视图", selection: selectedTabBinding) {
                        Image(systemName: "info.circle")
                            .accessibilityLabel("详情")
                            .tag(DetailTab.info)
                        Image(systemName: "curlybraces")
                            .accessibilityLabel("预览")
                            .tag(DetailTab.preview)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 88)
                }
            }
            ToolbarItem {
                Button {
                    model.presentsSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                .help("设置")
            }
        }
        .onChange(of: model.selectedModuleID) { _, _ in
            withAnimation(.snappy(duration: 0.18)) {
                selectedTab = .info
                hasPresentedPreview = false
            }
        }
    }

    private func kindID(_ kind: SelectionKind) -> String {
        switch kind {
        case .combined: "combined"
        case let .module(id): id.uuidString
        }
    }

    @ViewBuilder
    private func detailContent(for kind: SelectionKind) -> some View {
        // Keep both panes mounted after preview has been opened so unsaved
        // editor text survives tab switches; animate only visibility.
        ZStack {
            switch kind {
            case .combined:
                CombinedModuleDetailView()
                    .opacity(selectedTab == .info ? 1 : 0)
                    .offset(y: selectedTab == .info ? 0 : 6)
                    .allowsHitTesting(selectedTab == .info)
                if hasPresentedPreview {
                    CombinedPreviewPane()
                        .opacity(selectedTab == .preview ? 1 : 0)
                        .offset(y: selectedTab == .preview ? 0 : 6)
                        .allowsHitTesting(selectedTab == .preview)
                }
            case .module:
                if let module = selectedModule {
                    ModuleDetailView(module: module, onEdit: { editModule(module) })
                        .opacity(selectedTab == .info ? 1 : 0)
                        .offset(y: selectedTab == .info ? 0 : 6)
                        .allowsHitTesting(selectedTab == .info)
                    if hasPresentedPreview {
                        ModulePreviewPane(module: module)
                            .opacity(selectedTab == .preview ? 1 : 0)
                            .offset(y: selectedTab == .preview ? 0 : 6)
                            .allowsHitTesting(selectedTab == .preview)
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.22, extraBounce: 0.02), value: selectedTab)
    }
}
