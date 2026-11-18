import SwiftUI

struct ModuleEditorPreviewCard: View {
    let title: String
    let subtitle: String
    let publishedRelativePath: String
    let iconURL: URL?
    let iconIsInvalid: Bool
    let iconSourceTitle: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            DraftModuleIconPreview(
                url: iconURL,
                size: 42,
                isInvalid: iconIsInvalid
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    MetadataPill(iconSourceTitle, systemImage: iconIsInvalid ? "exclamationmark.triangle" : "photo", tint: iconIsInvalid ? Design.Palette.warning : nil)
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(publishedRelativePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .detailCard()
    }
}

struct ModuleEditorSection<Content: View>: View {
    let title: String
    private let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            GroupedCardStack {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ModuleEditorInfoRow<Content: View>: View {
    let title: String
    let icon: String
    private let content: () -> Content

    init(_ title: String, icon: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content
    }

    var body: some View {
        HStack(alignment: .center, spacing: Design.Row.spacing) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Design.Palette.icon)
                .frame(width: Design.Row.iconWidth, alignment: .center)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(width: Design.Row.labelWidth, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Design.Row.verticalPadding)
    }
}

struct ModuleEditorControlRow<Content: View>: View {
    let title: String
    let icon: String
    private let content: () -> Content

    init(_ title: String, icon: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content
    }

    var body: some View {
        ModuleEditorInfoRow(title, icon: icon) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ModuleEditorTextFieldRow: View {
    let title: String
    let icon: String
    @Binding var text: String
    let prompt: String
    var accessibilityIdentifier: String? = nil

    var body: some View {
        ModuleEditorControlRow(title, icon: icon) {
            TextField(title, text: $text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(accessibilityIdentifier ?? "module-editor.field.\(title)")
        }
    }
}

struct ModuleEditorToggleRow: View {
    let title: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        ModuleEditorControlRow(title, icon: icon) {
            HStack {
                Spacer(minLength: 0)
                Toggle(title, isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }
}

struct ModuleEditorOutputPathRow: View {
    let relativePath: String
    let notice: ModuleOutputPathNotice?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    outputPathText(fixedHorizontal: true)
                    Spacer(minLength: 4)
                    TextCopyButton(text: relativePath)
                        .layoutPriority(1)
                }
                VStack(alignment: .leading, spacing: 6) {
                    outputPathText(fixedHorizontal: false)
                    TextCopyButton(text: relativePath)
                }
            }
            if let notice {
                Label(notice.message, systemImage: notice.isWarning ? "exclamationmark.triangle" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(notice.isWarning ? Design.Palette.warning : .secondary)
            }
        }
    }

    private func outputPathText(fixedHorizontal: Bool) -> some View {
        Text(relativePath)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: fixedHorizontal, vertical: true)
            .frame(maxWidth: fixedHorizontal ? nil : .infinity, alignment: .leading)
    }
}

struct ModuleEditorFolderPicker: View {
    @Binding var outputFolder: String
    let folders: [String]
    let onCreateFolder: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { ModuleOutputFolder.normalized(outputFolder) },
                set: { outputFolder = $0 }
            )) {
                ForEach(folders, id: \.self) { folder in
                    Text(ModuleOutputFolder.displayTitle(for: folder)).tag(folder)
                }
            }
            .labelsHidden()

            Button(action: onCreateFolder) {
                Label("新建", systemImage: "folder.badge.plus")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("新建存放文件夹")
            .accessibilityLabel("新建存放文件夹")
        }
    }
}

struct ModuleEditorStorageLocationPicker: View {
    @Binding var storageLocation: ModuleStorageLocation

    var body: some View {
        Picker("模块存放", selection: $storageLocation) {
            ForEach(ModuleStorageLocation.allCases) { location in
                Label(location.title, systemImage: location.systemImage)
                    .tag(location)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 260, alignment: .leading)
    }
}

struct ModuleEditorStorageTargetsPicker: View {
    @Binding var storageTargets: Set<ModuleStorageLocation>

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ModuleStorageLocation.allCases) { location in
                Toggle(isOn: Binding(
                    get: { storageTargets.contains(location) },
                    set: { enabled in
                        if enabled { storageTargets.insert(location) }
                        else if storageTargets.count > 1 { storageTargets.remove(location) }
                    }
                )) {
                    Label(location.title, systemImage: location.systemImage)
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(location.detail)
            }
        }
    }
}

struct DraftModuleIconPreview: View {
    let url: URL?
    let size: CGFloat
    var isInvalid = false

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        previewContainer(
                            placeholder.overlay { ProgressView().controlSize(.mini) },
                            isWarning: isInvalid
                        )
                    case let .success(image):
                        previewContainer(image.resizable().scaledToFill(), isWarning: isInvalid)
                    case .failure:
                        previewContainer(warningPlaceholder, isWarning: true)
                    @unknown default:
                        previewContainer(placeholder, isWarning: isInvalid)
                    }
                }
            } else {
                previewContainer(placeholder, isWarning: isInvalid)
            }
        }
        .accessibilityHidden(true)
    }

    private func previewContainer<Content: View>(_ content: Content, isWarning: Bool) -> some View {
        content
            .frame(width: size, height: size)
            .background(Design.Palette.elevated, in: iconShape)
            .clipShape(iconShape)
            .overlay {
                iconShape
                    .strokeBorder(
                        isWarning ? Design.Palette.warning.opacity(0.72) : Design.Palette.stroke,
                        lineWidth: 1
                    )
            }
    }

    private var placeholder: some View {
        Image(systemName: isInvalid ? "exclamationmark.triangle" : "bolt.horizontal.fill")
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(isInvalid ? Design.Palette.warning : Design.Palette.accent.opacity(0.85))
            .frame(width: size, height: size)
    }

    private var warningPlaceholder: some View {
        Image(systemName: "exclamationmark.triangle")
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(Design.Palette.warning)
            .frame(width: size, height: size)
    }

    private var iconShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * ModuleIconView.cornerRadiusRatio, style: .continuous)
    }
}
