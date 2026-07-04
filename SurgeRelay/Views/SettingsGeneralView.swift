import AppKit
import SwiftUI

struct SettingsGeneralView: View {
    @Environment(AppModel.self) private var model
    @State private var isCheckingUpdate = false

    var body: some View {
        SettingsForm {
            generalSection
            automationSection
            scriptHubSection
        }
    }

    private var generalSection: some View {
        SettingsSection("通用") {
            SettingsControlRow("配置储存目录", icon: "folder") {
                SettingsPathSelectionControl(
                    path: model.configurationDirectoryPath,
                    chooseAction: chooseDirectory
                )
            }
            SettingsToggleRow("使用总模块功能", icon: "square.stack.3d.up", isOn: Binding(
                get: { model.settings.combinedModuleEnabled },
                set: { model.setCombinedModuleEnabled($0) }
            ))
            if model.settings.combinedModuleEnabled {
                SettingsTextFieldRow(
                    "总模块文件名",
                    icon: "doc",
                    text: combinedFileNameBinding,
                    prompt: "Surge-Relay"
                )
            }
            SettingsControlRow("软件更新", icon: "arrow.down.circle") {
                Button("检查更新", systemImage: "arrow.clockwise") {
                    model.presentsUpdateChecker = true
                }
            }
        }
    }

    private var automationSection: some View {
        SettingsSection("自动化") {
            SettingsControlRow("刷新间隔", icon: "clock.arrow.circlepath") {
                Picker("刷新间隔", selection: Binding(
                    get: { model.settings.refreshIntervalMinutes },
                    set: {
                        model.settings.refreshIntervalMinutes = $0
                        model.saveSettings()
                        model.restartScheduler()
                    }
                )) {
                    Text("手动").tag(0)
                    Text("每 15 分钟").tag(15)
                    Text("每小时").tag(60)
                    Text("每 6 小时").tag(360)
                    Text("每 12 小时").tag(720)
                }
                .labelsHidden()
                .frame(maxWidth: 220, alignment: .leading)
            }
            SettingsToggleRow("登录时启动", icon: "power", isOn: Binding(
                get: { model.settings.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            SettingsToggleRow("自动发布", icon: "arrow.up.doc", isOn: Binding(
                get: { model.settings.automaticallyPublish },
                set: {
                    model.settings.automaticallyPublish = $0
                    model.saveSettings()
                }
            ))
        }
    }

    private var scriptHubSection: some View {
        SettingsSection("Script-Hub") {
            SettingsCopyableInfoRow(
                "版本",
                value: model.upstreamState.revision.map { String($0.prefix(7)) } ?? "—",
                icon: "number",
                monospaced: true
            )
            SettingsCopyableInfoRow(
                "固定来源",
                value: model.upstreamState.sourceDescription ?? "尚未验证",
                icon: "pin"
            )
            SettingsCopyableInfoRow(
                "上游 revision",
                value: model.upstreamState.upstreamRevision.map { String($0.prefix(12)) } ?? "—",
                icon: "arrow.triangle.branch",
                monospaced: true
            )
            SettingsCopyableInfoRow(
                "脚本 hash",
                value: model.upstreamState.scriptHashes.isEmpty ? "尚未记录" : "\(model.upstreamState.scriptHashes.count) 个脚本已记录",
                icon: "checklist"
            )
            SettingsCopyableInfoRow(
                "上次检查",
                value: model.upstreamState.lastCheckedAt?.formatted(date: .abbreviated, time: .shortened) ?? "尚未检查",
                icon: "clock"
            )
            SettingsControlRow("上游模块", icon: "link") {
                TextField("上游模块", text: stringBinding(\.scriptHubModuleURL))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
            SettingsToggleRow("自动更新", icon: "arrow.triangle.2.circlepath", isOn: Binding(
                get: { model.settings.automaticallyUpdateScriptHub },
                set: {
                    model.settings.automaticallyUpdateScriptHub = $0
                    model.saveSettings()
                }
            ))
            SettingsControlRow("操作", icon: "ellipsis.circle") {
                HStack(spacing: 8) {
                    Button("检查更新", systemImage: "arrow.clockwise") {
                        Task {
                            isCheckingUpdate = true
                            await model.refreshScriptHub(showProgress: false)
                            isCheckingUpdate = false
                        }
                    }
                    .disabled(isCheckingUpdate)
                    if isCheckingUpdate {
                        ProgressView().controlSize(.small)
                        Text("正在检查…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let error = model.upstreamState.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    /// Edits the combined module file name without the `.sgmodule` extension so it
    /// can't be deleted by accident. The on-disk file always keeps the extension,
    /// since every consumer normalizes through `FilenameSanitizer.sgmoduleName`.
    private var combinedFileNameBinding: Binding<String> {
        Binding(
            get: {
                let value = model.settings.combinedModuleFileName
                return value.lowercased().hasSuffix(".sgmodule")
                    ? String(value.dropLast(".sgmodule".count))
                    : value
            },
            set: {
                model.settings.combinedModuleFileName = $0
                model.saveSettings()
            }
        )
    }

    private func stringBinding(_ keyPath: WritableKeyPath<AppSettings, String>) -> Binding<String> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: {
                model.settings[keyPath: keyPath] = $0
                model.saveSettings()
            }
        )
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(filePath: model.configurationDirectoryPath, directoryHint: .isDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.useConfigurationDirectory(url.path)
    }
}
