import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showsWebQRCode = false

    private var selection: Binding<SettingsPage?> {
        Binding(get: { model.settingsPage }, set: { if let page = $0 { model.settingsPage = page } })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section {
                    ForEach(SettingsPage.allCases) { page in
                        let isSelected = model.settingsPage == page
                        Button {
                            model.settingsPage = page
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: page.systemImage)
                                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? Design.Palette.accent : .secondary)
                                    .frame(width: 20, alignment: .center)
                                Text(page.title)
                                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? Design.Palette.accent : .primary)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .tag(page)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("settings.tab.\(page.rawValue)")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                } header: {
                    Text("设置")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 164, ideal: 184, max: 200)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: model.settingsPage.systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Design.Palette.accent)
                        .frame(width: 30, height: 30)
                        .background(Design.Palette.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.settingsPage.title)
                            .font(.system(size: 18, weight: .bold))
                        Text(pageDescription)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 8)

                selectedSettingsContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Design.Palette.canvas)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 480)
        .tint(Design.Palette.accent)
        .task {
            if !AppRuntimeOptions.isUIQAMode {
                model.ensureGitHubTokenLoaded()
                model.ensureWebAccessTokenForEditing()
            }
        }
        .sheet(isPresented: $showsWebQRCode) {
            if let url = model.webManagementURL, let displayURL = model.webManagementDisplayURL {
                VStack(spacing: 0) {
                    SheetHeader("扫码打开 Web 管理", subtitle: "局域网内移动设备可扫码进入工作台", systemImage: "qrcode")
                    VStack(spacing: 14) {
                        if let image = qrCodeImage(for: url.absoluteString) {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 220, height: 220)
                                .padding(12)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        Text(displayURL.absoluteString)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity)
                    .background(Design.Palette.canvas)

                    SheetActionFooter {
                        Spacer()
                        Button("完成") { showsWebQRCode = false }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .frame(minWidth: 340)
            }
        }
    }

    private var pageDescription: String {
        switch model.settingsPage {
        case .general: "配置外观、自动同步与内置引擎更新。"
        case .workspaces: "管理独立工作区、目录迁移与可复用模板。"
        case .publishing: "管理各客户端本地目录与 GitHub 仓库分发。"
        case .credentials: "管理保存在本机 AES-256-GCM 加密文件中的令牌。"
        case .webManagement: "开启本地或局域网浏览器远程管理界面。"
        case .diagnostics: "查看签名状态、运行环境自检与崩溃报告。"
        }
    }

    @ViewBuilder
    private var selectedSettingsContent: some View {
        switch model.settingsPage {
        case .general: SettingsGeneralView()
        case .workspaces: SettingsWorkspacesView()
        case .publishing: SettingsPublishingView()
        case .credentials: SettingsCredentialsView()
        case .webManagement: SettingsWebManagementView(showsWebQRCode: $showsWebQRCode)
        case .diagnostics: SettingsDiagnosticsView()
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
