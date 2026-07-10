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
                    Picker("视图", selection: $selectedTab) {
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
        .onChange(of: selectedTab) { _, newValue in
            if newValue == .preview {
                hasPresentedPreview = true
            }
        }
        .onChange(of: model.selectedModuleID) { _, _ in
            selectedTab = .info
            hasPresentedPreview = false
        }
    }

    @ViewBuilder
    private func detailContent(for kind: SelectionKind) -> some View {
        ZStack {
            switch kind {
            case .combined:
                CombinedModuleDetailView()
                    .opacity(selectedTab == .info ? 1 : 0)
                    .allowsHitTesting(selectedTab == .info)
                if hasPresentedPreview {
                    CombinedPreviewPane()
                        .opacity(selectedTab == .preview ? 1 : 0)
                        .allowsHitTesting(selectedTab == .preview)
                }
            case let .module(module):
                ModuleDetailView(module: module, onEdit: { editModule(module) })
                    .opacity(selectedTab == .info ? 1 : 0)
                    .allowsHitTesting(selectedTab == .info)
                if hasPresentedPreview {
                    ModulePreviewPane(module: module)
                        .opacity(selectedTab == .preview ? 1 : 0)
                        .allowsHitTesting(selectedTab == .preview)
                }
            }
        }
    }
}
