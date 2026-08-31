import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showsWebQRCode = false
    @State private var selectedTab: SettingsTab = .general
    @State private var backStack: [SettingsTab] = []
    @State private var forwardStack: [SettingsTab] = []
    @State private var isHistoryNavigation = false

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case general
        case publishing
        case credentials
        case webManagement
        case diagnostics

        var id: Self { self }

        var title: String {
            switch self {
            case .general: "通用"
            case .publishing: "发布"
            case .credentials: "凭据"
            case .webManagement: "Web 管理"
            case .diagnostics: "诊断"
            }
        }

        var controlWidth: CGFloat {
            switch self {
            case .webManagement: 94
            default: 72
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader

            selectedSettingsContent
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 440, idealHeight: 500)
        .background {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
        }
        .background(SettingsWindowChromeConfigurator())
        .task {
            if !AppRuntimeOptions.isUIQAMode {
                model.ensureGitHubTokenLoaded()
                model.ensureWebAccessTokenForEditing()
            }
        }
        .sheet(isPresented: $showsWebQRCode) {
            if let url = model.webManagementURL, let displayURL = model.webManagementDisplayURL {
                VStack(spacing: 18) {
                    Text("Web 管理").font(.title2.bold())
                    if let image = qrCodeImage(for: url.absoluteString) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 240, height: 240)
                    }
                    Text(displayURL.absoluteString)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Button("完成") { showsWebQRCode = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(28)
                .frame(minWidth: 330)
            }
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: 12) {
            settingsHistoryButtons
            Spacer(minLength: 0)
            settingsTabSelector
            Spacer(minLength: 0)
            // Keep the segmented control visually centered.
            Color.clear.frame(width: 72, height: 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .onChange(of: selectedTab) { oldValue, newValue in
            guard oldValue != newValue else { return }
            if isHistoryNavigation {
                isHistoryNavigation = false
                return
            }
            backStack.append(oldValue)
            forwardStack.removeAll()
        }
    }

    private var settingsHistoryButtons: some View {
        HStack(spacing: 0) {
            historyButton(
                systemImage: "chevron.left",
                isEnabled: !backStack.isEmpty,
                help: "返回上一个设置页",
                action: goBack
            )
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.22))
                .frame(width: 1, height: 17)
            historyButton(
                systemImage: "chevron.right",
                isEnabled: !forwardStack.isEmpty,
                help: "前进到下一个设置页",
                action: goForward
            )
        }
        .frame(width: 72, height: 32)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("设置页历史")
    }

    private func historyButton(
        systemImage: String,
        isEnabled: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 35, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .foregroundStyle(isEnabled ? Color.primary.opacity(0.72) : Color.secondary.opacity(0.28))
        .disabled(!isEnabled)
    }

    private func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(selectedTab)
        isHistoryNavigation = true
        withAnimation(.snappy(duration: 0.18)) {
            selectedTab = previous
        }
    }

    private func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(selectedTab)
        isHistoryNavigation = true
        withAnimation(.snappy(duration: 0.18)) {
            selectedTab = next
        }
    }

    private var settingsTabSelector: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                settingsTabButton(tab)
            }
        }
        .padding(4)
        .frame(width: SettingsTabMetrics.selectorWidth, height: SettingsTabMetrics.selectorHeight)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .accessibilityLabel("设置分类")
    }

    private func settingsTabButton(_ tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                selectedTab = tab
            }
        } label: {
            ZStack {
                Text(tab.title)
                    .font(.callout.weight(isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(width: tab.controlWidth, height: SettingsTabMetrics.itemHeight)
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings.tab.\(tab.rawValue)")
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.22), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
    }

    @ViewBuilder
    private var selectedSettingsContent: some View {
        switch selectedTab {
        case .general:
            SettingsGeneralView()
        case .publishing:
            SettingsPublishingView()
        case .credentials:
            SettingsCredentialsView()
        case .webManagement:
            SettingsWebManagementView(showsWebQRCode: $showsWebQRCode)
        case .diagnostics:
            SettingsDiagnosticsView()
        }
    }

    private func qrCodeImage(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
