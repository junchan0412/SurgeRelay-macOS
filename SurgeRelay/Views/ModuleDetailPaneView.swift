import SwiftUI

struct ModuleDetailPaneView: View {
    @Environment(AppModel.self) private var model
    let editModule: (RelayModule) -> Void
    let addModule: () -> Void
    let scanLocalModules: () -> Void
    let filterModules: (ModuleFilter) -> Void

    @State private var selectedTab: DetailTab = .info
    @State private var hasPresentedPreview = false

    private enum DetailTab: Hashable {
        case info
        case preview
    }

    private enum SelectionKind: Equatable {
        case module(UUID)
    }

    private var selectedTabBinding: Binding<DetailTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                withAnimation(.snappy(duration: 0.2, extraBounce: 0.02)) {
                    selectedTab = newValue
                    if newValue == .preview {
                        hasPresentedPreview = true
                    }
                }
            }
        )
    }

    private var selectionKind: SelectionKind? {
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
            if model.selectedModuleID == AppModel.activitySelectionID {
                ActivityHistoryView()
            } else if model.selectedModuleID == AppModel.conversionToolsSelectionID {
                ConversionToolsView()
            } else if let kind = selectionKind {
                detailContent(for: kind)
                    .id(kindID(kind))
            } else {
                WorkspaceOverviewView(
                    addModule: addModule,
                    scanLocalModules: scanLocalModules,
                    filterModules: filterModules
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .toolbar {
            if selectionKind != nil {
                ToolbarItem(placement: .primaryAction) {
                    Picker("视图", selection: selectedTabBinding) {
                        Label("概览", systemImage: "slider.horizontal.below.rectangle")
                            .accessibilityLabel("详情")
                            .help("查看模块概览与参数")
                            .tag(DetailTab.info)
                        Label("内容", systemImage: "curlybraces")
                            .accessibilityLabel("预览")
                            .help("查看或编辑模块正文")
                            .tag(DetailTab.preview)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 156)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.presentsSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                .help("设置（⌘,）")
                .accessibilityIdentifier("settings.open")
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
        case let .module(id): id.uuidString
        }
    }

    private func openPreviewTab() {
        selectedTabBinding.wrappedValue = .preview
    }

    @ViewBuilder
    private func detailContent(for kind: SelectionKind) -> some View {
        ZStack {
            switch kind {
            case .module:
                if let module = selectedModule {
                    ModuleDetailView(
                        module: module,
                        onEdit: { editModule(module) },
                        onOpenPreview: openPreviewTab
                    )
                    .opacity(selectedTab == .info ? 1 : 0)
                    .offset(y: selectedTab == .info ? 0 : 4)
                    .allowsHitTesting(selectedTab == .info)
                    .accessibilityHidden(selectedTab != .info)

                    if hasPresentedPreview {
                        ModulePreviewPane(module: module)
                            .opacity(selectedTab == .preview ? 1 : 0)
                            .offset(y: selectedTab == .preview ? 0 : 4)
                            .allowsHitTesting(selectedTab == .preview)
                            .accessibilityHidden(selectedTab != .preview)
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.2, extraBounce: 0.02), value: selectedTab)
    }
}
