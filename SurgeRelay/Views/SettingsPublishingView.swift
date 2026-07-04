import AppKit
import SwiftUI

struct SettingsPublishingView: View {
    @Environment(AppModel.self) private var model
    @State private var localRootDiagnostics: LocalModuleRootDiagnosticSnapshot?

    var body: some View {
        SettingsForm {
            storageLocationSection
            cloudflareWorkerSection
        }
        .task {
            refreshLocalRootDiagnostics()
        }
        .onChange(of: model.settings.localModuleDirectory) { _, _ in
            refreshLocalRootDiagnostics()
        }
    }

    private var storageLocationSection: some View {
        SettingsSection("存储位置") {
            SettingsToggleRow("发布到本地", icon: "folder", isOn: Binding(
                get: { model.settings.publishToLocal },
                set: { model.setPublishToLocal($0) }
            ))
            SettingsToggleRow("发布到 GitHub", icon: "cloud", isOn: Binding(
                get: { model.settings.publishToGitHub },
                set: { model.setPublishToGitHub($0) }
            ))

            if model.settings.publishToLocal {
                SettingsControlRow("本地根目录", icon: "folder") {
                    SettingsPathSelectionControl(
                        path: model.settings.localModuleDirectory,
                        chooseAction: chooseLocalModuleDirectory
                    )
                }
                SettingsInfoRow("文件规则", icon: "folder.badge.gearshape") {
                    Text(model.settings.combinedModuleEnabled ? "总模块保存在根目录；独立模块可选择根目录下的文件夹。" : "独立模块可选择根目录下的文件夹。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let diagnostics = localRootDiagnostics {
                    localRootDiagnosticContent(diagnostics)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在检查本地模块根目录…")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if model.settings.publishToGitHub {
                SettingsTextFieldRow("所有者", icon: "person", text: githubBinding(\.owner), prompt: "GitHub 用户或组织")
                SettingsTextFieldRow("仓库", icon: "tray.full", text: githubBinding(\.repository), prompt: "Repository")
                SettingsTextFieldRow("分支", icon: "arrow.triangle.branch", text: githubBinding(\.branch), prompt: "main")
                SettingsTextFieldRow("模块根目录", icon: "folder", text: githubBinding(\.directory), prompt: "modules 或 surge/modules")
                SettingsInfoRow("仓库类型", icon: repositoryTypeIcon) {
                    switch model.settings.github.repositoryIsPrivate {
                    case .some(true): Label("私有", systemImage: "lock.fill")
                    case .some(false): Label("公开", systemImage: "globe")
                    case nil: Text("未检测").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var cloudflareWorkerSection: some View {
        if model.settings.publishToGitHub, model.settings.github.repositoryIsPrivate == true {
            SettingsSection("Cloudflare Worker") {
                SettingsTextFieldRow(
                    "公共地址",
                    icon: "network",
                    text: githubBinding(\.publicBaseURL),
                    prompt: "https://example.workers.dev"
                )
            }
        }
    }

    private var repositoryTypeIcon: String {
        switch model.settings.github.repositoryIsPrivate {
        case .some(true): "lock.fill"
        case .some(false): "globe"
        case nil: "questionmark.circle"
        }
    }

    private func chooseLocalModuleDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(filePath: model.settings.localModuleDirectory, directoryHint: .isDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setLocalModuleDirectory(url.path)
    }

    private func refreshLocalRootDiagnostics() {
        Task { @MainActor in
            let path = model.settings.localModuleDirectory
            let snapshot = await Task.detached(priority: .utility) {
                LocalModuleRootDiagnosticSnapshot.current(path: path)
            }.value
            localRootDiagnostics = snapshot
        }
    }

    private func localRootDiagnosticContent(_ diagnostics: LocalModuleRootDiagnosticSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsInfoRow("根目录状态", icon: "folder") {
                Label(diagnostics.status, systemImage: localRootDiagnosticImage(diagnostics))
                    .foregroundStyle(localRootDiagnosticColor(diagnostics))
                    .textSelection(.enabled)
            }
            SettingsInfoRow("写入权限", icon: diagnostics.isWritable ? "pencil" : "lock.fill") {
                Label(diagnostics.isWritable ? "可写" : "不可写", systemImage: diagnostics.isWritable ? "pencil" : "lock.fill")
                    .foregroundStyle(diagnostics.isWritable ? .green : .orange)
            }
            SettingsCopyableInfoRow(
                "目录内容",
                value: "\(diagnostics.folderCount) 个文件夹 · \(diagnostics.moduleFileCount) 个 .sgmodule",
                icon: "shippingbox"
            )
            if let error = diagnostics.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button("重新检查", systemImage: "arrow.clockwise") {
                    refreshLocalRootDiagnostics()
                }
                Button("在 Finder 中显示", systemImage: "folder") {
                    NSWorkspace.shared.open(URL(filePath: diagnostics.path, directoryHint: .isDirectory))
                }
                .disabled(!diagnostics.exists || !diagnostics.isDirectory)
            }
        }
    }

    private func localRootDiagnosticImage(_ diagnostics: LocalModuleRootDiagnosticSnapshot) -> String {
        if diagnostics.exists, diagnostics.isDirectory, diagnostics.isWritable, diagnostics.error == nil {
            return "checkmark.circle.fill"
        }
        return "exclamationmark.triangle.fill"
    }

    private func localRootDiagnosticColor(_ diagnostics: LocalModuleRootDiagnosticSnapshot) -> Color {
        diagnostics.exists && diagnostics.isDirectory && diagnostics.isWritable && diagnostics.error == nil
            ? .green
            : .orange
    }

    private func githubBinding(_ keyPath: WritableKeyPath<GitHubSettings, String>) -> Binding<String> {
        Binding(
            get: { model.settings.github[keyPath: keyPath] },
            set: {
                model.settings.github[keyPath: keyPath] = $0
                model.saveSettings()
            }
        )
    }
}
