import AppKit
import SwiftUI

struct SettingsPublishingView: View {
    @Environment(AppModel.self) private var model
    @State private var localRootDiagnostics: [ModuleOutputFormat: LocalModuleRootDiagnosticSnapshot] = [:]

    var body: some View {
        SettingsForm {
            storageLocationSection
            if model.settings.publishToLocal {
                ForEach(ModuleOutputFormat.allCases) { format in
                    clientStorageSection(format)
                }
            }
            githubStorageSection
            cloudflareWorkerSection
        }
        .disabled(model.isWorking)
        .task(id: localDiagnosticInputs) { await refreshLocalRootDiagnostics() }
    }

    private var storageLocationSection: some View {
        SettingsSection("存储位置") {
            SettingsToggleRow("发布到本地", icon: "folder", isOn: Binding(
                get: { model.settings.publishToLocal },
                set: { model.setPublishToLocal($0) }
            ))
            .accessibilityIdentifier("settings.local-publishing")
            Text("启用的客户端使用各自的根目录，模块可选择根目录下的文件夹。默认只启用 Surge。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func clientStorageSection(_ format: ModuleOutputFormat) -> some View {
        let storage = model.settings.localStorage(for: format)
        return SettingsSection(format.title) {
            SettingsToggleRow("启用本地存储", icon: "folder", isOn: Binding(
                get: { model.settings.localStorage(for: format).isEnabled },
                set: { model.setClientLocalStorageEnabled($0, for: format) }
            ))
            .accessibilityIdentifier("settings.local-storage.\(format.rawValue)")
            if storage.isEnabled {
                SettingsControlRow("存储目录", icon: "folder") {
                    if storage.directory.isEmpty {
                        HStack(spacing: 10) {
                            Text("请选择目录").font(.callout).foregroundStyle(.secondary)
                            Button("选择…") { chooseLocalModuleDirectory(for: format) }
                        }
                    } else {
                        SettingsPathSelectionControl(path: storage.directory) { chooseLocalModuleDirectory(for: format) }
                    }
                }
                .accessibilityIdentifier("settings.local-directory.\(format.rawValue)")
                if !storage.directory.isEmpty {
                    if let diagnostics = localRootDiagnostics[format] {
                        DisclosureGroup("目录检查") { localRootDiagnosticContent(diagnostics).padding(.top, 8) }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在检查目录…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var githubStorageSection: some View {
        SettingsSection("GitHub 发布") {
            SettingsToggleRow("发布到 GitHub", icon: "cloud", isOn: Binding(
                get: { model.settings.publishToGitHub },
                set: { model.setPublishToGitHub($0) }
            ))

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

    private func chooseLocalModuleDirectory(for format: ModuleOutputFormat) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let path = model.settings.localStorage(for: format).directory
        if !path.isEmpty { panel.directoryURL = URL(filePath: path, directoryHint: .isDirectory) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setClientLocalModuleDirectory(url.path, for: format)
    }

    private var localDiagnosticInputs: [String] {
        [String(model.settings.publishToLocal)] + ModuleOutputFormat.allCases.map { format in
            let storage = model.settings.localStorage(for: format)
            return "\(format.rawValue):\(storage.isEnabled):\(storage.directory)"
        }
    }

    private func refreshLocalRootDiagnostics() async {
        let inputs = localDiagnosticInputs
        let paths = ModuleOutputFormat.allCases.compactMap { format -> (ModuleOutputFormat, String)? in
            let storage = model.settings.localStorage(for: format)
            return model.settings.publishToLocal && storage.isEnabled && !storage.directory.isEmpty ? (format, storage.directory) : nil
        }
        localRootDiagnostics = [:]
        let worker = Task.detached(priority: .utility) {
            var result: [ModuleOutputFormat: LocalModuleRootDiagnosticSnapshot] = [:]
            for (format, path) in paths {
                guard !Task.isCancelled else { break }
                result[format] = LocalModuleRootDiagnosticSnapshot.current(path: path)
            }
            return result
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, inputs == localDiagnosticInputs else { return }
        localRootDiagnostics = result
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
                    .foregroundStyle(diagnostics.isWritable ? Design.Palette.success : Design.Palette.warning)
            }
            SettingsCopyableInfoRow(
                "目录内容",
                value: "\(diagnostics.folderCount) 个文件夹 · \(diagnostics.moduleFileCount) 个模块文件",
                icon: "shippingbox"
            )
            if let error = diagnostics.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Design.Palette.warning)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button("重新检查", systemImage: "arrow.clockwise") {
                    Task { await refreshLocalRootDiagnostics() }
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
            ? Design.Palette.success
            : Design.Palette.warning
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
