import SwiftUI

struct ModuleEditorBasicInfoSection: View {
    @Binding var name: String
    @Binding var storageLocation: ModuleStorageLocation
    @Binding var category: String
    @Binding var outputFolder: String
    let sourceOrigin: ModuleSourceOrigin
    let relationshipHint: String
    let folders: [String]
    let onCreateFolder: () -> Void

    var body: some View {
        ModuleEditorSection("基本信息") {
            ModuleEditorTextFieldRow(title: "显示名称", icon: "textformat", text: $name, prompt: "例如：YouTube 去广告")
            ModuleEditorControlRow("模块存放", icon: storageLocation.systemImage) {
                ModuleEditorStorageLocationPicker(storageLocation: $storageLocation)
            }
            ModuleEditorInfoRow("关系", icon: sourceOrigin.systemImage) {
                Text(relationshipHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ModuleEditorTextFieldRow(title: "模块标签", icon: "tag", text: $category, prompt: "Surge category，例如：广告过滤")
            ModuleEditorControlRow("存放文件夹", icon: "folder") {
                ModuleEditorFolderPicker(
                    outputFolder: $outputFolder,
                    folders: folders,
                    onCreateFolder: onCreateFolder
                )
            }
        }
    }
}

struct ModuleEditorIconSection: View {
    @Binding var iconURL: String
    let displayedIconPreviewURL: URL?
    let hasCustomIconInput: Bool
    let customIconInputIsInvalid: Bool
    let iconURLHint: String

    var body: some View {
        ModuleEditorSection("图标") {
            ModuleEditorControlRow("图标 URL", icon: "photo") {
                HStack(spacing: 8) {
                    TextField("图标 URL", text: $iconURL, prompt: Text("https://example.com/icon.png"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    if hasCustomIconInput {
                        Button {
                            iconURL = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help("清空自定义图标")
                    }
                    DraftModuleIconPreview(
                        url: displayedIconPreviewURL,
                        size: 30,
                        isInvalid: customIconInputIsInvalid
                    )
                }
            }
            ModuleEditorInfoRow(customIconInputIsInvalid ? "检查" : "兼容性", icon: customIconInputIsInvalid ? "exclamationmark.triangle" : "info.circle") {
                Text(iconURLHint)
                    .font(.caption)
                    .foregroundStyle(customIconInputIsInvalid ? .orange : .secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ModuleEditorPublishingSection: View {
    @Binding var isEnabled: Bool
    @Binding var publishesStandalone: Bool
    @Binding var outputFileName: String
    let combinedModuleEnabled: Bool
    let publishedRelativePath: String
    let outputPathNotice: ModuleOutputPathNotice?

    var body: some View {
        ModuleEditorSection("发布") {
            if combinedModuleEnabled {
                ModuleEditorToggleRow(title: "包含在总模块中", icon: "square.stack.3d.up", isOn: $isEnabled)
            }
            ModuleEditorToggleRow(title: "发布为独立模块", icon: "doc.badge.gearshape", isOn: $publishesStandalone)
            ModuleEditorTextFieldRow(title: "输出文件名", icon: "doc", text: $outputFileName, prompt: "留空时根据显示名称生成")
            ModuleEditorInfoRow("输出路径", icon: "folder") {
                ModuleEditorOutputPathRow(
                    relativePath: publishedRelativePath,
                    notice: outputPathNotice
                )
            }
        }
    }
}

struct ModuleEditorSourceSection: View {
    @Binding var sourceURL: String
    @Binding var sourceFormat: ModuleSourceFormat

    var body: some View {
        ModuleEditorSection("转换前来源") {
            ModuleEditorTextFieldRow(
                title: "来源地址",
                icon: "link",
                text: $sourceURL,
                prompt: "https://example.com/module.plugin 或 file:///.../Demo.sgmodule"
            )
            ModuleEditorControlRow("来源格式", icon: "doc.text") {
                Picker("来源格式", selection: $sourceFormat) {
                    ForEach(ModuleSourceFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220, alignment: .leading)
            }
        }
    }
}

struct ModuleEditorConversionSection: View {
    @Binding var isAdvancedExpanded: Bool
    @Binding var scriptHubOptions: ScriptHubOptions
    let isNativeSurgeModule: Bool

    var body: some View {
        ModuleEditorSection("转换") {
            Button {
                withAnimation(.snappy) { isAdvancedExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .rotationEffect(.degrees(isAdvancedExpanded ? 90 : 0))
                    Text("高级")
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isAdvancedExpanded {
                if isNativeSurgeModule {
                    Label(
                        "该地址是 Surge 模块，将直接参与合并，不经过 Script-Hub；高级转换选项不会应用。",
                        systemImage: "arrow.triangle.branch"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                } else {
                    ScriptHubAdvancedOptionsView(options: $scriptHubOptions)
                }
            }
            Text("Loon 与 Quantumult X 来源可在这里使用 Script-Hub 原有的转换控制。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
