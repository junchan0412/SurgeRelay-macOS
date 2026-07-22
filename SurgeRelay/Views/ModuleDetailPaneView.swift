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

    private enum SelectionKind {
        case combined
        case module(RelayModule)
    }

    private var selectedTabBinding: Binding<DetailTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                withAnimation(.snappy(duration: 0.2)) {
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
           let module = model.modules.first(where: { $0.id == id }) {
            return .module(module)
        }
        return nil
    }

    var body: some View {
        Group {
            if let kind = selectionKind {
                detailContent(for: kind)
            } else {
                ContentUnavailableView("选择一个模块", systemImage: "sidebar.right")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    @ViewBuilder
    private func detailContent(for kind: SelectionKind) -> some View {
        // Keep both panes mounted after preview has been opened so unsaved
        // editor text survives tab switches; animate only visibility.
        ZStack {
            switch kind {
            case .combined:
                CombinedModuleDetailView()
                    .opacity(selectedTab == .info ? 1 : 0)
                    .scaleEffect(selectedTab == .info ? 1 : 0.992, anchor: .top)
                    .allowsHitTesting(selectedTab == .info)
                if hasPresentedPreview {
                    CombinedPreviewPane()
                        .opacity(selectedTab == .preview ? 1 : 0)
                        .scaleEffect(selectedTab == .preview ? 1 : 0.992, anchor: .top)
                        .allowsHitTesting(selectedTab == .preview)
                }
            case let .module(module):
                ModuleDetailView(module: module, onEdit: { editModule(module) })
                    .id("info-\(module.id.uuidString)")
                    .opacity(selectedTab == .info ? 1 : 0)
                    .scaleEffect(selectedTab == .info ? 1 : 0.992, anchor: .top)
                    .allowsHitTesting(selectedTab == .info)
                if hasPresentedPreview {
                    ModulePreviewPane(module: module)
                        .id("preview-\(module.id.uuidString)")
                        .opacity(selectedTab == .preview ? 1 : 0)
                        .scaleEffect(selectedTab == .preview ? 1 : 0.992, anchor: .top)
                        .allowsHitTesting(selectedTab == .preview)
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: selectedTab)
    }
}
