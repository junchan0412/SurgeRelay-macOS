import AppKit
import SwiftUI

struct SettingsWebManagementView: View {
    @Environment(AppModel.self) private var model
    @Binding var showsWebQRCode: Bool

    var body: some View {
        SettingsForm {
            serviceSection
            accessSection
        }
    }

    private var serviceSection: some View {
        SettingsSection("服务") {
            SettingsInfoRow("服务状态", icon: model.webServerState.systemImage) {
                Label(model.webServerState.title, systemImage: model.webServerState.systemImage)
                    .foregroundStyle(webServerStateColor)
                    .textSelection(.enabled)
            }
            SettingsToggleRow("启用服务", icon: "network", isOn: Binding(
                get: { model.settings.webServerEnabled },
                set: {
                    model.settings.webServerEnabled = $0
                    model.applyWebServerSettings()
                }
            ))
            SettingsControlRow("端口", icon: "number") {
                TextField("端口", value: Binding(
                    get: { model.settings.webServerPort },
                    set: { model.settings.webServerPort = $0 }
                ), format: .number.grouping(.never))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120, alignment: .leading)
                .onChange(of: model.settings.webServerPort) { _, _ in
                    if model.settings.webServerEnabled {
                        model.applyWebServerSettings()
                    }
                }
            }
            SettingsToggleRow("局域网访问", icon: "network", isOn: Binding(
                get: { model.settings.webServerAllowRemoteAccess },
                set: {
                    model.settings.webServerAllowRemoteAccess = $0
                    model.applyWebServerSettings()
                }
            ))
            .disabled(!model.settings.webServerEnabled)
            if model.settings.webServerEnabled {
                SettingsInfoRow("访问范围", icon: model.settings.webServerAllowRemoteAccess ? "network" : "desktopcomputer") {
                    Label(
                        model.webManagementAccessModeTitle,
                        systemImage: model.settings.webServerAllowRemoteAccess ? "network" : "desktopcomputer"
                    )
                    .foregroundStyle(model.settings.webServerAllowRemoteAccess ? .orange : .secondary)
                }
            }
            if let failure = model.webServerState.failureMessage {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var accessSection: some View {
        SettingsSection("访问") {
            if let displayURL = model.webManagementDisplayURL, let url = model.webManagementURL {
                SettingsCopyableInfoRow(
                    title: model.settings.webServerAllowRemoteAccess ? "局域网地址" : "本机地址",
                    value: displayURL.absoluteString,
                    icon: "link",
                    monospaced: true,
                    copyValue: url.absoluteString
                )
                SettingsControlRow("操作", icon: "ellipsis.circle") {
                    HStack {
                        Button("打开", systemImage: "safari") { NSWorkspace.shared.open(url) }
                        Button("拷贝访问链接", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                        Button("二维码", systemImage: "qrcode") { showsWebQRCode = true }
                    }
                }
                if model.settings.webServerAllowRemoteAccess {
                    Label("局域网访问会暴露模块管理入口，请只在可信网络中启用。", systemImage: "lock.open.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("启用 Web 管理后会显示访问地址。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var webServerStateColor: Color {
        switch model.webServerState {
        case .running: .green
        case .failed: .red
        case .starting, .stopped: .secondary
        }
    }
}
