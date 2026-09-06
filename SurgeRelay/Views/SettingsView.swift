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
                        Button { model.settingsPage = page } label: {
                            Label(page.title, systemImage: page.systemImage)
                                .font(.system(size: 14))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .tag(page)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("settings.tab.\(page.rawValue)")
                        .accessibilityAddTraits(model.settingsPage == page ? .isSelected : [])
                    }
                } header: {
                    Text("设置").font(.title2.weight(.semibold)).foregroundStyle(.primary).padding(.vertical, 16)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 190)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.settingsPage.title).font(.system(size: 25, weight: .bold))
                    Text(pageDescription).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 4)
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
                VStack(spacing: 18) {
                    Text("Web 管理").font(.title2.bold())
                    if let image = qrCodeImage(for: url.absoluteString) {
                        Image(nsImage: image).interpolation(.none).resizable().frame(width: 240, height: 240)
                    }
                    Text(displayURL.absoluteString).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Button("完成") { showsWebQRCode = false }.keyboardShortcut(.defaultAction)
                }.padding(28).frame(minWidth: 330)
            }
        }
    }

    private var pageDescription: String {
        switch model.settingsPage {
        case .general: "配置自动更新、启动行为与总模块。"
        case .publishing: "选择输出目录，连接 GitHub，管理稳定订阅地址。"
        case .credentials: "管理保存在本机加密文件中的访问凭据。"
        case .webManagement: "通过浏览器管理模块，按需开启访问。"
        case .diagnostics: "检查运行环境、来源目录与服务状态。"
        }
    }

    @ViewBuilder
    private var selectedSettingsContent: some View {
        switch model.settingsPage {
        case .general: SettingsGeneralView()
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
